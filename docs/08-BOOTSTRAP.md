# 08 — Bootstrap : premier déploiement

Procédure complète pour monter l'infra from scratch.
À suivre dans l'ordre — chaque étape dépend de la précédente.

**Une seule action manuelle** : se connecter au dashboard NetBird, créer le compte admin, récupérer le token API, le stocker dans vault. Tout le reste est automatisé par Ansible.

---

## Rôles impliqués

```
netbird_server  → déploie le serveur NetBird (management + signal + relay + STUN)
netbird_config  → crée les groupes + ACLs via l'API NetBird (automatisé)
netbird_client  → crée une setup key via API + enroll automatique (automatisé)
```

Le rôle `netbird_client` supporte aussi le mode manuel (`-e netbird_client_setup_key=XXX`).

---

## Prérequis

Tout ça doit être prêt AVANT de lancer Ansible.

### Infrastructure

```
VPS créé (Terraform ou manuel)
  → Debian 12, accès root par SSH, IP publique connue

Pi flashé
  → Debian 12 (Raspberry Pi OS Lite), accès root par SSH, connecté au réseau local

Domaine configuré
  → DNS A record : netbird.domaine.fr → IP publique VPS
  → DNS A record : *.domaine.fr → IP publique VPS (wildcard pour les services publics)
  → Les sous-domaines privés ne sont PAS dans le DNS public (AdGuard mesh les résout)
```

### Clés SSH (deux paires distinctes)

```
Clé admin (ta clé perso)
  → ssh-keygen -t ed25519 -C "admin@zero-trust"
  → Utilisée pour l'accès humain aux serveurs
  → Stockée sur ton laptop uniquement
  → JAMAIS dans GitHub

Clé deploy (dédiée CI/CD)
  → ssh-keygen -t ed25519 -C "deploy@zero-trust"
  → Utilisée par Ansible (GitHub Runner ou laptop)
  → Clé privée dans GitHub Secrets
  → Clé publique sur chaque serveur (user deploy)
```

### Ansible Vault

```
Choisir un mot de passe vault fort (généré, >32 chars)
  → Stocké dans GitHub Secrets (ANSIBLE_VAULT_PASSWORD)
  → Stocké dans Vaultwarden une fois déployé
  → En attendant Vaultwarden : dans ta tête ou un fichier local .vault_pass (gitignored)
```

---

## Étape 0 — Remplir les TO_FILL

Les fichiers de configuration contiennent des placeholders `TO_FILL`.
Les remplir AVANT de lancer Ansible.

### 0.1 — group_vars/all.yml

```yaml
# Source de vérité unique — tous les sous-domaines en dérivent
base_domain: "TONDOMAINE.fr"

# Clés SSH publiques (communes à toutes les machines, pas des secrets)
base_admin_ssh_pubkey: "ssh-ed25519 AAAA... admin@zero-trust"
base_deploy_ssh_pubkey: "ssh-ed25519 AAAA... deploy@zero-trust"

# NetBird — domaine dérivé automatiquement de base_domain
netbird_domain: "mesh.{{ base_domain }}"
```

`base_domain` est la seule variable à personnaliser.
`netbird_domain` en dérive automatiquement (`mesh.TONDOMAINE.fr`).
Les clés SSH publiques ne sont pas des secrets → pas dans vault.

### 0.2 — inventory/hosts.yml

```yaml
# Seul le VPS est dans l'inventaire au départ.
# Le Pi sera décommenté après le Sprint 0 VPS.
vps:
  ansible_host: "IP_PUBLIQUE_VPS"
  ansible_port: 22         # premier run (root, port 22)
  ansible_user: root       # premier run (deploy n'existe pas encore)
```

### 0.3 — host_vars/vps.yml

```yaml
# Plus de domaines ni d'email ici.
# Tout est dérivé de base_domain (group_vars/all.yml)
# et vault_admin_email (group_vars/all_vault.yml).
# Seuls restent : firewall, traefik mode, options spécifiques VPS.
```

### 0.4 — host_vars/vps_vault.yml

```bash
# Générer les secrets
openssl rand -base64 32   # → vault_netbird_auth_secret
openssl rand -base64 32   # → vault_netbird_store_encryption_key

# Remplir le fichier puis chiffrer
ansible-vault encrypt host_vars/vps_vault.yml
```

```yaml
vault_netbird_auth_secret: "<généré ci-dessus>"
vault_netbird_store_encryption_key: "<généré ci-dessus>"
vault_netbird_auth_owner_email: "admin@TONDOMAINE.fr"
vault_netbird_auth_owner_password: "<mot de passe admin fort>"
```

> **Note** : `vault_netbird_api_token` n'est PAS ici. Il est dans `group_vars/all_vault.yml`
> (commun à toutes les machines) et sera rempli à l'étape 1.4.

### 0.5 — group_vars/all_vault.yml

```yaml
vault_netbird_api_token: ""   # LAISSER VIDE — rempli à l'étape 1.4
```

```bash
ansible-vault encrypt group_vars/all_vault.yml
```

### 0.6 — Clés SSH (deux paires distinctes)

Si pas encore générées :

```bash
ssh-keygen -t ed25519 -f ~/.ssh/admin_key -C "admin@zero-trust"
ssh-keygen -t ed25519 -f ~/.ssh/deploy_key -C "deploy@zero-trust"
```

**Deux clés, deux usages :**

- **Clé admin** — ta clé perso, sur le laptop uniquement, JAMAIS dans GitHub.
  Sert au premier déploiement et aux accès d'urgence.
- **Clé deploy** — dédiée CI/CD, sur le laptop + GitHub Secrets.
  Si compromise → révoquer sans perdre l'accès admin.
- Les deux clés **publiques** vont dans `group_vars/all.yml` (pas vault, ce ne sont pas des secrets)
- La clé deploy **privée** ira dans GitHub Secrets plus tard (Sprint CI/CD)

### 0.7 — Après le hardening SSH (étape 1.2)

Mettre à jour `inventory/hosts.yml` :

```yaml
vps:
  ansible_port: 2222       # ← changé (SSH durci)
  ansible_user: deploy     # ← changé (user deploy créé)
```

### 0.8 — Après le Sprint 0 VPS (étape 2)

Décommenter la section Pi dans `inventory/hosts.yml` :

```yaml
private:
  hosts:
    pi:
      ansible_host: "100.64.x.x"   # IP mesh, connue après enrollment VPS
      ansible_port: 22              # premier run
      ansible_user: root            # premier run
      ansible_ssh_common_args: "-o ProxyJump=deploy@IP_VPS:2222"
```

---

## Étape 1 — VPS (premier nœud)

Le VPS est le premier nœud car il héberge le serveur NetBird.
Sans lui, pas de mesh, pas de Pi.

### 1.1 — Fichiers host_vars

```bash
# Variables non sensibles
cat > host_vars/vps.yml << 'EOF'
# Variables spécifiques au VPS
# netbird_domain est dérivé de base_domain (dans group_vars/all.yml)
# netbird_client_group est déduit de l'inventaire Ansible :
#   le VPS est dans le groupe "dmz" → netbird_client_group = "dmz" (auto)
base_nftables_input_tcp_allow:
  - 80    # Traefik Edge HTTP
  - 443   # Traefik Edge HTTPS
base_nftables_input_udp_allow:
  - 3478  # NetBird STUN
base_nftables_output_allow:
  - { dest: "9.9.9.9", port: 53, proto: "udp" }
  - { dest: "1.1.1.1", port: 53, proto: "udp" }
  - { dest: "0.0.0.0/0", port: 443, proto: "tcp" }
  - { dest: "0.0.0.0/0", port: 80, proto: "tcp" }
EOF

# Clés SSH publiques → dans group_vars/all.yml (voir étape 0.1)

# Secrets (chiffrés)
ansible-vault create host_vars/vps_vault.yml
# Contenu :
#   vault_netbird_auth_secret: "<openssl rand -base64 32>"
#   vault_netbird_store_encryption_key: "<openssl rand -base64 32>"
#   vault_netbird_auth_owner_email: "admin@domaine.fr"
#   vault_netbird_auth_owner_password: "<mot de passe admin fort>"
# NOTE : vault_netbird_api_token est dans group_vars/all_vault.yml (pas ici)
```

### 1.2 — Premier run : socle + NetBird Server (token absent)

```bash
# Premier run : l'inventaire a déjà ansible_user: root et ansible_port: 22
# Le token API NetBird est vide → netbird_config et netbird_client SKIP
# automatiquement (condition dans les rôles)
# Hostinger injecte la clé admin à la création du VPS → pas besoin de --ask-pass
# Si ton provider ne gère pas l'injection de clé : utiliser --ask-pass à la place
ansible-playbook playbooks/site.yml --tags infra \
  -i inventory/hosts.yml --limit vps \
  --private-key ~/.ssh/admin_key

# Ce run déploie :
#   1. base         → OS, users, SSH hardening, nftables
#   2. docker       → Docker CE + socket proxy
#   3. netbird_server → serveur NetBird (management + signal + relay)
#   4. netbird_config → SKIP (token API vide)
#   5. netbird_client → SKIP (token API vide, pas de setup key)
```

```bash
# Vérifie que ça marche
ssh lucas@IP_VPS -p 2222           # ✅ nouveau port SSH
ssh root@IP_VPS -p 22              # ❌ refusé (root off, port changé)

# MAINTENANT : mettre à jour inventory/hosts.yml (voir étape 0.7)
#   ansible_port: 2222
#   ansible_user: deploy
```

À partir de maintenant, Ansible se connecte en `deploy@IP_VPS:2222`.

### 1.3 — Action manuelle (la seule)

Le serveur NetBird tourne. Il faut récupérer le token API.

```
1. Ouvrir https://netbird.domaine.fr dans un navigateur
2. Créer le compte admin avec les credentials de vault :
     vault_netbird_auth_owner_email / vault_netbird_auth_owner_password
3. Dashboard → Settings → Personal Access Tokens → Create Token
     → Name : "ansible"
     → Copier le token généré
4. Stocker le token dans vault :
     ansible-vault edit group_vars/all_vault.yml
     → vault_netbird_api_token: "<le token copié>"
```

C'est la SEULE action manuelle de tout le bootstrap.
Le token API permet à Ansible de piloter NetBird pour tout le reste.

### 1.4 — Deuxième run : config + enrollment (token présent)

```bash
# Relancer le playbook complet. Cette fois le token API est rempli.
# Les rôles base/docker/netbird_server sont idempotents (0 changed).
# netbird_config et netbird_client s'exécutent.
ansible-playbook playbooks/site.yml --tags infra \
  -i inventory/hosts.yml --limit vps

# Ce run fait :
#   1. base/docker/netbird_server → 0 changed (idempotent)
#   2. netbird_config → crée les groupes + policies ACLs
#   3. netbird_client → crée setup key + enroll le VPS
```

Ce que `netbird_config` fait via l'API NetBird :

```
Groupes créés :
  admin   → tes devices perso (laptop, téléphone)
  dmz     → VPS et futurs VPS
  private → Pi et futurs nœuds privés
  agents  → tous les nœuds avec Bientôt Agent

Policies ACLs créées (voir docs/03-FLUX.md) :
  POLICY 1 : admin → dmz         → ALL
  POLICY 2 : admin → private     → ALL
  POLICY 3 : dmz → private       → UDP :53 (AdGuard DNS)
  POLICY 4 : agents → private    → TCP :3002 (Bientôt Agent → Master)
  POLICY 5 : private → dmz       → TCP :443 (Ntfy) + TCP :PORT_SSH (backup)
  dmz → dmz : pas de policy = deny-by-default (NetBird bloque implicitement)
  POLICY 6 : private → private   → TCP :3002 (Bientôt Agent → Master)
```

Idempotent : relancer ne crée pas de doublons.

```bash
# Vérifier l'enrollment
sudo netbird status                 # ✅ Connected
ip addr show wt0                    # ✅ IP mesh 100.64.x.x visible
```

---

## Étape 2 — Pi (deuxième nœud)

Le Pi rejoint le mesh existant. Le serveur NetBird est déjà opérationnel.

### 2.1 — Fichiers host_vars

```bash
cat > host_vars/pi.yml << 'EOF'
# Variables spécifiques au Pi
# netbird_client_group est déduit de l'inventaire Ansible :
#   le Pi est dans le groupe "private" → netbird_client_group = "private" (auto)
# Pas de ports input ouverts (mesh only)
base_nftables_output_allow:
  - { dest: "9.9.9.9", port: 53, proto: "udp" }
  - { dest: "1.1.1.1", port: 53, proto: "udp" }
  - { dest: "9.9.9.9", port: 853, proto: "tcp" }
  - { dest: "0.0.0.0/0", port: 443, proto: "tcp" }
EOF

# host_vars/pi_vault.yml existe déjà (placeholder)
# À compléter au fur et à mesure des sprints Pi
# vault_netbird_api_token est dans group_vars/all_vault.yml (commun, pas besoin de le dupliquer)
```

### 2.2 — Socle complet (un seul run)

```bash
# L'inventaire a déjà ansible_user: root et ansible_port: 22 pour le Pi
# Utiliser --private-key ou --ask-pass selon le provider
ansible-playbook playbooks/site.yml --tags infra \
  -i inventory/hosts.yml --limit pi \
  --private-key ~/.ssh/admin_key

# Ansible exécute dans l'ordre :
#   1. base         → OS, SSH, nftables
#   2. docker       → Docker CE + socket proxy
#   3. netbird_client → crée setup key (API) + enroll (groupe "private")

# APRÈS : mettre à jour inventory/hosts.yml pour le Pi
#   ansible_port: 2222
#   ansible_user: deploy
```

### 2.3 — Vérifier le mesh

```bash
# Depuis le Pi
sudo netbird status                  # ✅ Connected, groupe private
ping IP_MESH_VPS                     # ✅ Pi → VPS OK

# Depuis le VPS
ping IP_MESH_PI                      # ✅ VPS → Pi OK
```

---

## Étape 3 — Machine future

Procédure générique pour tout nouveau nœud. Zéro action manuelle.

```
1. Ajouter la machine dans l'inventaire :
   → Groupe "dmz" si exposée à internet
   → Groupe "private" si mesh-only
   → Le rôle netbird_client déduit le groupe NetBird automatiquement

2. Créer les fichiers :
   → host_vars/<hostname>.yml
   → host_vars/<hostname>_vault.yml (secrets spécifiques à la machine)
   → vault_netbird_api_token est déjà dans group_vars/all_vault.yml (commun)

3. Déployer :
   ansible-playbook playbooks/site.yml --tags infra \
     -i inventory/hosts.yml --limit <hostname> \
     -u root --private-key ~/.ssh/admin_key

4. Vérifier :
   sudo netbird status               # ✅ Connected
   ping <IP_MESH_VPS>                # ✅ mesh OK
```

Pas de setup key à copier-coller. Le rôle `netbird_client` la crée via l'API
et l'utilise automatiquement. La clé est one-time et consommée immédiatement.

---

## Post-déploiement

### Vérifications mesh

```bash
# Depuis le VPS
sudo netbird status                  # Connected, groupe dmz
ping IP_MESH_PI                      # ✅

# Depuis le Pi
sudo netbird status                  # Connected, groupe private
ping IP_MESH_VPS                     # ✅

# Depuis ton laptop (si NetBird installé, groupe admin)
ping IP_MESH_VPS                     # ✅
ping IP_MESH_PI                      # ✅
```

### Étapes suivantes

```
Le socle est en place (Sprint 0 terminé).

Sprint 1 → traefik edge + portfolio = le site est UP
  ansible-playbook playbooks/site.yml \
    -i inventory/hosts.yml --limit vps --tags services

Voir docs/07-DEVPLAN.md pour la suite.
```

---

## Récapitulatif : ce qui est automatisé vs manuel

```
PREMIER RUN VPS (token API vide) :
  → base + docker + netbird_server = le serveur tourne
  → netbird_config SKIP (token absent)
  → netbird_client SKIP (token absent, pas de setup key)

MANUEL (une seule fois, étape 1.3) :
  → Se connecter au dashboard NetBird
  → Créer le compte admin
  → Récupérer le token API
  → Le stocker dans group_vars/all_vault.yml (vault_netbird_api_token)

DEUXIÈME RUN VPS (token présent) :
  → base/docker/netbird_server → 0 changed (idempotent)
  → netbird_config → crée les 4 groupes + 6 policies ACLs via API
  → netbird_client → crée setup key + enroll le VPS

MACHINES SUIVANTES (token déjà dans group_vars) :
  → Un seul run suffit : base + docker + netbird_client
  → Zéro action manuelle
```

---

## Pourquoi une setup key par machine

```
Le rôle netbird_client crée une setup key one-time pour chaque machine.
Le groupe NetBird est déduit du groupe Ansible dans l'inventaire :

  VPS dans groupe Ansible "dmz"     → setup key groupe "dmz"     → policies dmz
  Pi  dans groupe Ansible "private" → setup key groupe "private"  → policies private

Le groupe détermine les ACLs mesh (voir docs/03-FLUX.md).
La clé est créée, utilisée, et consommée dans la même exécution Ansible.
Rien à copier-coller, rien à nettoyer.

Mode fallback : si besoin, on peut passer une setup key manuellement :
  ansible-playbook ... -e netbird_client_setup_key="XXXXX"
```
