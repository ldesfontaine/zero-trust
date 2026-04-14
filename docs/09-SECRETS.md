# 09 — Gestion des secrets

## Chaîne de dépendances

```
Vault password → déchiffre host_vars/ → contient tous les tokens → injectés dans .env → services
Clé GPG privée → déchiffre backups .tar.gz.gpg → données Seafile, Vaultwarden, Bientôt
Clé SSH Ed25519 → accès machines → nécessaire pour Ansible ET backup SCP
```

**Si tu perds le vault password, tu perds TOUT.**

---

## Secrets d'accès (nécessaires pour reconstruire)

| Secret | Backup hors-infra | Si perdu |
|--------|-------------------|----------|
| Vault password Ansible | Papier coffre physique + USB | Tout à recréer from scratch |
| Clé SSH privée | USB air-gapped | Régénérer + bootstrap |
| Clé SSH deploy | USB air-gapped | Régénérer |
| Clé GPG privée backup | USB air-gapped | Backups VPS illisibles |
| Token API Hostinger | Régénérable dashboard | Régénérer |

## Inventaire complet des secrets applicatifs

### Tokens inter-services (hex 32 octets)

| Variable | Fichiers .env | Services consommateurs | Si perdu |
|----------|---------------|------------------------|----------|
| `vault_bientot_token_vps` | `sentinel-bientot.env`, `bientot-server.env` | bientot-agent VPS → bientot-server | Régénérer, redémarrer agent VPS + serveur |
| `vault_bientot_token_pi` | `bientot-agent-pi.env`, `bientot-server.env` | bientot-agent Pi → bientot-server | Régénérer, redémarrer agent Pi + serveur |
| `vault_veille_token` | `veille.env`, `bientot-server.env` | bientot-server → veille-secu API | Régénérer, redémarrer bientot-server + veille-secu |
| `vault_ntfy_auth_token` | `sentinel-bientot.env`, `bientot-server.env`, `veille.env`, health-check.sh, backup-vps.sh | Tous les scripts d'alerte + services | Recréer user ntfy CLI, redémarrer TOUT |
| `vault_crowdsec_lapi_key` | `sentinel.env` | crowdsec-firewall-bouncer | Régénérer + `cscli bouncers add` |
| `vault_crowdsec_bientot_key` | `sentinel-bientot.env` | bientot-agent VPS → CrowdSec API | Régénérer + `cscli bouncers add` |

### Credentials services (passwords/tokens)

| Variable | Fichiers .env | Service | Si perdu |
|----------|---------------|---------|----------|
| `vault_seafile_db_root_password` | `brain.env` | seafile-db (MariaDB) | Reset : `docker exec seafile-db mysql -e "ALTER USER..."` |
| `vault_seafile_admin_email` | `brain.env` | seafile | Mettre à jour dans admin panel |
| `vault_seafile_admin_password` | `brain.env` | seafile | Reset via admin panel ou API |
| `vault_vaultwarden_admin_token` | `brain.env` | vaultwarden | Régénérer (données intactes, juste l'admin panel) |
| `vault_immich_db_password` | `brain.env` | immich-db (PostgreSQL) | Reset : `docker exec immich-db psql -c "ALTER USER..."` |
| `vault_immich_db_user` | `brain.env` | immich-db | Changer dans PostgreSQL + Ansible |
| `vault_immich_db_name` | `brain.env` | immich-db | Ne pas changer (migration DB) |
| `vault_adguard_admin_user` | `brain.env`, `bientot-agent-pi.env` | adguard, bientot-agent Pi | Changer dans AdGuard UI + Ansible |
| `vault_adguard_admin_password` | `brain.env`, `bientot-agent-pi.env` | adguard, bientot-agent Pi | Changer dans AdGuard UI + Ansible |
| `vault_adguard_admin_password_hash` | Inline dans adguard.yml | adguard config | `htpasswd -nbBC 10 "" "nouveau_mdp" \| cut -d: -f2` |

### Infrastructure réseau

| Variable | Fichiers .env | Service | Si perdu |
|----------|---------------|---------|----------|
| `vault_netbird_datastore_key` | docker-compose backbone | netbird-server | Perte DB → ré-enrollment TOTAL de tous les peers |
| `vault_netbird_relay_secret` | docker-compose backbone | netbird-server relay | Régénérer, redémarrer NetBird server |
| `vault_netbird_api_token` | mesh-config tasks (ACL) | Ansible → NetBird API | Régénérer dans NetBird dashboard |
| `vault_admin_public_ip` | crowdsec whitelist | CrowdSec admin whitelist | Mettre à jour (risque auto-ban sinon) |

---

## Procédures de rotation

### Rotation d'un token Bientôt (vault_bientot_token_vps ou _pi)

```bash
# 1. Générer le nouveau token
NEW_TOKEN=$(openssl rand -hex 32)
echo "Nouveau token : ${NEW_TOKEN}"

# 2. Mettre à jour dans ansible-vault
ansible-vault edit host_vars/vps_serv.yml    # vault_bientot_token_vps
ansible-vault edit host_vars/pi_serv.yml     # vault_bientot_token_pi

# 3. Redéployer les .env concernés
ansible-playbook -i inventory.ini playbooks/services.yml --tags bientot --ask-vault-pass

# Services redémarrés : bientot-server + bientot-agent (VPS ou Pi selon le token)
```

### Rotation du token Ntfy (vault_ntfy_auth_token)

⚠️ **Impact large** : tous les scripts d'alerte + bientot-server + veille-secu.

```bash
# 1. Générer le nouveau token
NEW_TOKEN=$(openssl rand -hex 32)

# 2. Recréer le token dans Ntfy
ssh vps 'docker exec ntfy ntfy token remove <ancien_token>'
ssh vps 'docker exec ntfy ntfy token add --token "${NEW_TOKEN}" alerts'

# 3. Mettre à jour ansible-vault
ansible-vault edit host_vars/vps_serv.yml    # vault_ntfy_auth_token

# 4. Redéployer TOUT (health-check, backup, bientot, veille-secu)
ansible-playbook -i inventory.ini playbooks/services.yml --ask-vault-pass

# Services redémarrés : bientot-server, veille-secu, health-check cron, backup cron
```

### Rotation CrowdSec LAPI key (vault_crowdsec_lapi_key)

```bash
# 1. Générer la nouvelle clé
NEW_KEY=$(openssl rand -hex 32)

# 2. Mettre à jour ansible-vault
ansible-vault edit host_vars/vps_serv.yml    # vault_crowdsec_lapi_key

# 3. Redéployer (met à jour sentinel.env + bouncer config)
ansible-playbook -i inventory.ini playbooks/services.yml --tags crowdsec --ask-vault-pass

# 4. Ré-enregistrer le bouncer (si nécessaire)
ssh vps 'docker exec crowdsec cscli bouncers add firewall --key "${NEW_KEY}"'

# Services redémarrés : crowdsec, crowdsec-firewall-bouncer
```

### Rotation Veille-secu token (vault_veille_token)

```bash
NEW_TOKEN=$(openssl rand -hex 32)
ansible-vault edit host_vars/pi_serv.yml     # vault_veille_token
ansible-playbook -i inventory.ini playbooks/services.yml --tags veille-secu,bientot --ask-vault-pass

# Services redémarrés : veille-secu, bientot-server (consomme VEILLE_TOKEN)
```

### Rotation clé SSH admin

```bash
# 1. Générer nouvelle clé
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_vps_homelab -C "admin@homelab"

# 2. Injecter sur les machines (depuis l'ancienne clé encore active)
ssh-copy-id -i ~/.ssh/id_ed25519_vps_homelab.pub -p 2222 user@vps
ssh-copy-id -i ~/.ssh/id_ed25519_vps_homelab.pub -p 2222 user@pi

# 3. Tester la connexion AVANT de supprimer l'ancienne
ssh -i ~/.ssh/id_ed25519_vps_homelab -p 2222 user@vps whoami

# 4. Supprimer l'ancienne clé des authorized_keys
# 5. Mettre à jour le backup USB air-gapped
```

---

## Fréquence recommandée

| Secret | Fréquence | Raison |
|--------|-----------|--------|
| Tokens Bientôt/Veille | Annuel | Tokens internes, faible exposition |
| Token Ntfy | Annuel | Exposé dans scripts cron |
| CrowdSec LAPI key | Annuel | Interne VPS uniquement |
| Passwords DB (Seafile, Immich) | Annuel ou si compromission | Internes Docker network |
| Clé SSH admin | Annuel ou si laptop volé/compromis | Accès critique |
| Clé SSH deploy | Annuel | CI/CD, stockée dans GitHub Secrets |
| NetBird API token | Annuel | Accès management API |
| Vault password Ansible | 2 ans ou si compromission | Aucune exposition réseau |
| Clé GPG backup | 3 ans | Chiffrement asymétrique, clé privée hors-infra |

---

## Stockage USB air-gapped

SSD/clé USB chiffré LUKS. Contient :
```
/secrets/
├── id_ed25519_vps_homelab + .pub
├── id_ed25519_deploy + .pub
├── backup-gpg-private.asc
├── backup-gpg-public.asc
└── vault-password.txt
```

Mise à jour : à chaque régénération de clé. Minimum annuel pour vérifier la lisibilité.

---

## Rotation d'urgence (compromission suspectée)

```bash
# 1. Tourner TOUS les tokens en un seul run
for var in vault_bientot_token_vps vault_bientot_token_pi vault_veille_token \
           vault_ntfy_auth_token vault_crowdsec_lapi_key vault_crowdsec_bientot_key; do
  echo "${var}: $(openssl rand -hex 32)"
done
# → Copier dans ansible-vault edit host_vars/*.yml

# 2. Recréer le token Ntfy (seul qui nécessite une action hors Ansible)
ssh vps 'docker exec ntfy ntfy token remove <ancien> && ntfy token add --token <nouveau> alerts'

# 3. Redéployer tout
ansible-playbook -i inventory.ini playbooks/services.yml --ask-vault-pass

# 4. Tourner les clés SSH
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_vps_homelab
# ... injection + test (voir procédure ci-dessus)

# 5. Mettre à jour le backup USB
```
