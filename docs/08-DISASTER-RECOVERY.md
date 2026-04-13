# 08 — Disaster Recovery

> **Checklists de crise. Pas de prose, juste les étapes.**

## Prérequis de reconstruction

| Élément | Si perdu |
|---------|----------|
| Vault password Ansible | **Tout est perdu.** Rien n'est récupérable. |
| Clé SSH Ed25519 | Régénérer + bootstrap |
| Clé GPG privée backup | Backups VPS illisibles, USB uniquement |
| Backup USB LUKS | Restore VPS uniquement (données critiques, pas Immich) |

Stockage hors-infra : voir `09-SECRETS.md`.

---

## Scénario A — VPS mort, Pi intact

**Temps :** 15-20 min + ré-enrollment. **Impact :** Tous les services web down, Pi injoignable via mesh.

```bash
# 1. Recréer le VPS
terraform apply                       # → nouvelle IP → inventory.ini

# 2. DNS A records → nouvelle IP (TOUS les sous-domaines, voir 01-MACHINES.md)

# 3. Bootstrap + Phase 1
ansible-playbook playbooks/bootstrap.yml --limit dmz --ask-vault-pass
ansible-playbook playbooks/infrastructure.yml --limit dmz --ask-vault-pass

# 4. Enrollment — TOUTES les machines (NetBird server est neuf)
#    VPS + Pi + laptop + phone → voir 03-WORKFLOW.md étape 4
#    → host_vars/ avec nouvelles IPs NetBird

# 5. Phase 2
ansible-playbook playbooks/services.yml --ask-vault-pass
ansible-playbook playbooks/mesh-config.yml --ask-vault-pass

# 6. Ntfy : recréer user + token
docker exec ntfy ntfy user add --role=admin lucas
docker exec ntfy ntfy token add lucas
# → vault_ntfy_auth_token → relancer services.yml
```

## Scénario B — Pi mort, NVMe intacts

**Temps :** 30 min. **Impact :** Services privés down, VPS renvoie 502.

```bash
# 1. Nouveau Pi, flasher Debian
# 2. Brancher les NVMe existants
ansible-playbook playbooks/bootstrap.yml --limit lan --ask-vault-pass
ansible-playbook playbooks/infrastructure.yml --limit lan --ask-vault-pass

# 3. Importer le pool ZFS existant
ssh lucas@<PI> && sudo zpool import tank

# 4. Enrollment Pi
sudo netbird up --setup-key <KEY> --management-url https://mesh.domain.com
# → host_vars/pi_serv.yml

# 5. Services + mesh-config
ansible-playbook playbooks/services.yml --limit lan --ask-vault-pass
ansible-playbook playbooks/mesh-config.yml --ask-vault-pass
```

## Scénario C — Pi mort, NVMe morts

**Temps :** 1-2h. **Perte :** Données depuis dernier backup. Immich PAS dans backup VPS.

```bash
# 1. Nouveau Pi + NVMe
ansible-playbook playbooks/bootstrap.yml --limit lan --ask-vault-pass

# 2. Créer le pool ZFS
ssh lucas@<PI> && sudo zpool create tank mirror /dev/nvme0n1 /dev/nvme1n1

# 3. Phase 1 (crée l'arborescence vide)
ansible-playbook playbooks/infrastructure.yml --limit lan --ask-vault-pass

# 4. Enrollment + Phase 2 (containers vides)
# ...enrollment...
ansible-playbook playbooks/services.yml --limit lan --ask-vault-pass

# 5. Restore
ansible-playbook playbooks/restore.yml -e restore_source=vps --ask-vault-pass   # ou usb
ansible-playbook playbooks/services.yml --limit lan --ask-vault-pass              # restart
ansible-playbook playbooks/mesh-config.yml --ask-vault-pass
```

## Scénario D — Tout mort
Scénario A complet, puis scénario C complet.

## Scénario E — Auto-ban CrowdSec
```bash
# Depuis un autre réseau (4G) :
ssh lucas@<VPS> && docker exec crowdsec cscli decisions delete --ip <TON_IP>
# Ou : console VNC du provider, ou attendre 4h (expiration par défaut)
```
Prévention : whitelist `vault_admin_public_ip` dans `services-vps`.

## Scénario F — Ansible crashe pendant hardening SSH
Le connection-resolver cascade : port durci → port 22 → IP LAN → IP NetBird. En dernier recours : console VNC (VPS) ou clavier physique (Pi).

---

## Tester les backups (mensuel)

```bash
mkdir /tmp/restore-test
scp lucas@<VPS_NETBIRD>:/opt/backups/brain-01/$(ssh lucas@<VPS_NETBIRD> "ls -t /opt/backups/brain-01/ | head -1") /tmp/restore-test/
gpg --decrypt --output /tmp/restore-test/backup.tar.gz /tmp/restore-test/*.gpg
tar -tzf /tmp/restore-test/backup.tar.gz | grep -E "seafile|vaultwarden|bientot"
rm -rf /tmp/restore-test
```
