# 05 — Déploiement, Backup & Disaster Recovery

## Principe : le code Ansible n'est JAMAIS sur les serveurs

```
GitHub Runner → clone frais depuis GitHub (source de vérité)
             → ansible-playbook DEPUIS LE RUNNER
             → SSH vers VPS/Pi pour exécuter les tasks

Le repo n'est JAMAIS sur le VPS ni le Pi.
Un serveur compromis ne peut pas modifier le code de déploiement.
```

---

## versions.yml — source de vérité

```yaml
# NON VAULT — éditable depuis GitHub mobile
# Chaque version = un tag d'image sur GHCR ou Docker Hub

# Images custom (GHCR)
portfolio: "1.3.0"
bientot-agent: "0.8.2"
bientot-server: "0.8.2"
veille-secu: "2.1.0"

# Images tierces (Docker Hub)
traefik: "3.1"
crowdsec: "1.6.3"
vaultwarden: "1.32.5"
seafile: "11.0.13"
immich: "1.99.0"
adguard: "0.107.52"
ntfy: "2.11.0"
bentopdf: "1.2.0"
```

---

## Trois workflows

### Workflow 1 — CI lint (automatique)

```
Trigger : push sur main ou PR
Runner  : GitHub-hosted
Accès   : aucun (pas de SSH, pas de deploy)

Actions :
  - ansible-lint + yamllint
  - ansible-playbook --syntax-check
  - Si versions.yml modifié → valide YAML + vérifie images GHCR
  - Vérification signature GPG du commit (optionnel)
```

### Workflow 2 — Deploy service (manuel, rapide)

```
Trigger : workflow_dispatch
Inputs  : service (choice) + machine (choice)

Quand   : bump de version d'un service existant
Change  : UNIQUEMENT l'image du container
Ne change PAS : firewall, .env, réseaux, mesh

Flow :
  1. Clone frais du repo depuis GitHub
  2. Lire version depuis versions.yml
  3. cosign verify (vérifier signature image)
  4. ansible-playbook update-service.yml
     → SSH vers cible (VPS direct ou Pi via jump host)
     → docker compose pull (become: true)
     → docker compose up -d (become: true)
     → health check
  5. Notification Ntfy succès/échec
```

### Workflow 3 — Deploy infra (manuel, complet)

```
Trigger : workflow_dispatch
Inputs  : playbook + tags + limit + mode (check/apply)

Quand   : changement d'infra, nouveau service, secrets,
          firewall, ACLs, ajout de machine
Change  : tout ce qu'Ansible gère

Flow :
  1. Clone frais du repo depuis GitHub
  2. Valider signature GPG du dernier commit
  3. ansible-playbook <playbook choisi>
     → SSH vers cibles via jump host
     → Applique les changements (idempotent)
  4. Notification Ntfy succès/échec
```

### Quand utiliser quel workflow

| Je veux... | Workflow |
|------------|----------|
| Bumper la version d'un service | 2 |
| Ajouter un NOUVEAU service | 3 |
| Changer les ports firewall | 3 |
| Ajouter une machine au mesh | 3 |
| Modifier le hardening SSH | 3 |
| Changer les ACLs NetBird | 3 |
| Modifier un secret (.env) | 3 |
| Premier déploiement from scratch | 3 |

---

## SSH — jump host

```
Le runner GitHub ne peut pas joindre le Pi directement (mesh-only).
Le VPS forward la connexion SSH via le mesh. Il n'exécute rien.

Host vps
  HostName IP_PUBLIQUE_VPS
  Port PORT_SSH_DURCI
  User deploy
  IdentityFile ~/.ssh/deploy_key

Host pi
  HostName 100.64.x.x
  User deploy
  ProxyJump vps
  IdentityFile ~/.ssh/deploy_key
```

---

## User deploy — permissions

```
Même config sur VPS et Pi :
  - SSH par clé uniquement (pas de password)
  - Shell : /bin/bash (Ansible nécessite un shell fonctionnel)
  - Clé SSH dédiée (≠ clé admin)

Sudoers :
  deploy ALL=(root) NOPASSWD: ALL

SSH hardening (sshd_config) :
  Match User deploy
    AllowTcpForwarding yes
    PermitOpen 100.64.x.x:22
    X11Forwarding no
    AllowAgentForwarding no
```

---

## Protection contre compromission

```
Signature GPG des commits :
  → Workflow 3 vérifie la signature avant d'exécuter
  → Commit non signé → workflow refuse

Signature images Docker (cosign) :
  → Build : cosign sign
  → Deploy : cosign verify avant pull
  → Tag GHCR compromis → détecté

GitHub Environment Protection :
  → Environment "production" → approval manuelle requise

GitHub Secrets :
  → Clé SSH deploy, vault password, clé cosign
  → Jamais dans le repo, jamais sur les serveurs
```

---

## Deploy d'urgence — fallback GitHub down

```
Depuis ton laptop avec ta clé admin (PAS deploy) :
  1. Repo cloné localement (git pull régulier)
  2. ansible-playbook -i inventory.ini playbooks/<playbook>.yml \
       --ask-vault-pass --limit <machine>
  3. SSH direct : admin@VPS ou admin@Pi via mesh

Procédure d'urgence uniquement. La clé admin n'est PAS dans GitHub.
Testée 1x pour vérifier que ça marche.
```

---

## Backup — stratégie 3-2-1

### Principe

```
Copie 1 — ZFS mirror (Pi)
  2 NVMe en mirror. Protection hardware.
  PAS un backup : rm -rf est répliqué.

Copie 2 — SSD USB externe (LUKS, air-gapped)
  TOUT : snapshot complet du Pi incluant Immich.
  Chiffré LUKS. Débranché en temps normal.
  Survit à : ransomware, compromission Pi, rm -rf, surtension.

Copie 3 — VPS (GPG, données critiques uniquement)
  Données irremplaçables, chiffrées AVANT envoi.
  Le VPS ne voit JAMAIS les données en clair.
  Survit à : destruction physique du Pi + SSD USB.
```

### Ce qui est backupé où

| Donnée | Disque externe | VPS | Justification |
|--------|:-:|:-:|------|
| Vaultwarden (SQLite) | ✅ | ✅ | Critique — perte = bloqué partout |
| Seafile (fichiers + DB) | ✅ | ✅ | Fichiers utilisateur irremplaçables |
| Immich (photos + DB) | ✅ | ❌ | Trop volumineux. Originaux sur téléphone. |
| Bientôt (DB métriques) | ✅ | ❌ | Reconstituable |
| Veille Sécu (DB CVE) | ✅ | ❌ | Re-fetchable |
| NetBird Server (config + DB) | ❌ | ✅ | Critique — perte = mesh à reconfigurer |
| Configs services | ❌ | ❌ | Ansible les redéploie |
| Images Docker | ❌ | ❌ | Re-pullables depuis GHCR |
| Code apps | ❌ | ❌ | Dans GitHub |

### Mécanismes

```
Disque externe (SSD USB LUKS) :
  1. Brancher SSD (détection udev)
  2. Déchiffrer LUKS
  3. ZFS snapshot atomique → zfs send → SSD
  4. Démonter + débrancher
  Fréquence : hebdomadaire (manuel ou udev trigger)
  Rétention : 4 derniers snapshots

VPS (GPG chiffré) :
  1. Dump données critiques (Vaultwarden SQLite, Seafile DB + fichiers)
  2. Compression : tar + zstd
  3. Chiffrement : GPG asymétrique (clé privée JAMAIS sur le VPS)
  4. Envoi : rsync via mesh → VPS:/opt/backups/
  5. Purge : rétention 7 jours
  Fréquence : quotidien (cron)
```

### Sécurité backup

```
Clé GPG privée  : UNIQUEMENT sur ton laptop. Jamais Pi, jamais VPS.
Clé GPG publique : sur le Pi (pour chiffrer).
Passphrase LUKS  : dans ta tête (seul secret non numérique).
Test restauration : à faire 1x AVANT d'en avoir besoin.
```

---

## Backup cert TLS (acme.json)

Traefik stocke clé privée ACME + certificats dans `acme.json` (bind mount
`/opt/modules/traefik/letsencrypt/`). Sans backup, un wipe du VPS = nouveau
challenge Let's Encrypt → risque de rate limit (5 certs identiques / 7 jours).

### Après le premier deploy avec cert valide obtenu

```bash
# 1. Rapatrier acme.json depuis le VPS
scp -P 2222 -i ~/.ssh/id_ed25519_deploy \
  deploy@<VPS_IP>:/opt/modules/traefik/letsencrypt/acme.json /tmp/acme.json

# 2. Chiffrer avec ansible-vault
ansible-vault encrypt /tmp/acme.json \
  --output backups/traefik/acme.json.vault

# 3. Supprimer la copie en clair
rm /tmp/acme.json

# 4. Commit
git add backups/traefik/acme.json.vault
git commit -m "feat: backup acme.json cert TLS"
```

### Comportement automatique

- Chaque `ansible-playbook site.yml` vérifie si `backups/traefik/acme.json.vault` existe
- Si oui **ET** que l'hôte n'a pas encore d'`acme.json` → restauration automatique (décryptée via vault password) avant démarrage Traefik
- Si l'hôte a déjà un `acme.json` → on n'y touche pas (sinon on perdrait les renouvellements récents)
- Si aucun backup ni cert sur l'hôte → warning + demande Let's Encrypt standard

### Sécurité

- `acme.json` en clair ne doit JAMAIS être commit — `.gitignore` bloque `backups/**/*.json` (whitelist `*.vault`)
- Seul le fichier `.vault` chiffré est traqué par git
- La clé privée ACME reste protégée par le mot de passe ansible-vault

---

## Disaster Recovery

| Scénario | Action | Données perdues |
|----------|--------|-----------------|
| Un service crash | `docker compose down && up` — volumes ZFS intacts | Aucune |
| Pi corrompu (rm -rf, ransomware) | Restaurer depuis SSD USB (snapshot ZFS) + Ansible configs | Données depuis dernier snapshot |
| Pi détruit (vol, incendie) | Nouveau hardware + Ansible from scratch + backups GPG depuis VPS | Immich (sauf si SSD récupéré) |
| VPS compromis | Reconstruire via Terraform + Ansible. Backups chiffrés illisibles. Aucun impact Pi. | Aucune |
| Clé SSH deploy fuitée | Révoquer clé GitHub, regénérer, redéployer via workflow 3 | Aucune |
| Compte GitHub compromis | Signature GPG bloque les commits non signés. Approval manuelle bloque les deploys. | Aucune |
