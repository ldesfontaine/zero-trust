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

## Secrets applicatifs (dans ansible-vault, récréables)

| Variable | Si perdu |
|----------|----------|
| `vault_seafile_db_root_password` | Reset MySQL |
| `vault_vaultwarden_admin_token` | Régénérer (données intactes) |
| `vault_immich_db_password` | Reset PostgreSQL |
| `vault_crowdsec_lapi_key` | Régénérer + réenregistrer bouncer |
| `vault_netbird_datastore_key` | Perte DB NetBird → ré-enrollment total |
| `vault_ntfy_auth_token` | Recréer user + token CLI Ntfy |
| `vault_bientot_token_*` | Régénérer `openssl rand -hex 32` |
| `vault_admin_public_ip` | Mettre à jour (whitelist CrowdSec) |

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

## Rotation

| Événement | Tourner quoi |
|-----------|-------------|
| Laptop volé | Clé SSH → régénérer + authorized_keys |
| Compromission suspectée | TOUS les secrets applicatifs → redéployer |
| Annuellement | Tokens API, passwords applicatifs |

```bash
openssl rand -hex 32                        # nouveau token
ansible-vault edit host_vars/pi_serv.yml    # mettre à jour
ansible-playbook playbooks/services.yml --ask-vault-pass   # redéployer .env
```
