# 03 — Workflow de déploiement

## Playbooks

```
playbooks/
├── bootstrap.yml          ← Run 0 : users admin
├── infrastructure.yml     ← Phase 1 : socle + mesh (VPS + Pi)
├── services.yml           ← Phase 2 : apps + backup + monitoring
├── mesh-config.yml        ← Phase 2 : ACLs + DNS
├── site.yml               ← Raccourci : infrastructure + services + mesh-config
└── restore.yml            ← Disaster recovery
```

---

## infrastructure.yml

```yaml
---
# Phase 1 — VPS
- name: "Infrastructure Sentinelle (VPS)"
  hosts: dmz
  become: true
  gather_facts: false
  ignore_unreachable: true
  pre_tasks:
    - include_role: { name: connection-resolver }
      tags: [always]
    - include_role: { name: netbird-client, tasks_from: resolve.yml }
      tags: [always]
  roles:
    - { role: common,         tags: [common] }
    - { role: base-vps,       tags: [base, hardening, nftables, ssh] }
    - { role: docker,         tags: [docker] }
    - { role: backbone,       tags: [backbone, traefik, netbird-server] }
    - { role: netbird-client, tags: [netbird-client] }

# Phase 1 — Pi
- name: "Infrastructure Cerveau (Pi)"
  hosts: lan
  become: true
  gather_facts: false
  ignore_unreachable: true
  pre_tasks:
    - include_role: { name: connection-resolver }
      tags: [always]
    - include_role: { name: netbird-client, tasks_from: resolve.yml }
      tags: [always]
  roles:
    - { role: common,         tags: [common] }
    - { role: base-pi,        tags: [base, hardening, ufw, ssh] }
    - { role: docker,         tags: [docker] }
    - { role: netbird-client, tags: [netbird-client] }
```

**Résultat :** Firewall UP, SSH durci, Docker installé, Traefik + NetBird server UP, clients NetBird installés (pas encore enrôlés). `mesh.domain.com` est accessible → enrollment possible.

---

## services.yml

```yaml
---
# Phase 2 — VPS
- name: "Services Sentinelle (VPS)"
  hosts: dmz
  become: true
  gather_facts: false
  ignore_unreachable: true
  pre_tasks:
    - include_role: { name: connection-resolver }
      tags: [always]
    - include_role: { name: netbird-client, tasks_from: resolve.yml }
      tags: [always]
  roles:
    - { role: services-vps,  tags: [services, crowdsec, ntfy, bientot-agent] }
    - { role: monitoring,    tags: [monitoring, grype] }

# Phase 2 — Pi
- name: "Services Cerveau (Pi)"
  hosts: lan
  become: true
  gather_facts: false
  ignore_unreachable: true
  pre_tasks:
    - include_role: { name: connection-resolver }
      tags: [always]
    - include_role: { name: netbird-client, tasks_from: resolve.yml }
      tags: [always]
  roles:
    - { role: services-pi,  tags: [services, seafile, vaultwarden, immich, adguard, bientot, veille-secu, portfolio] }
    - { role: backup,       tags: [backup, zfs] }
    - { role: monitoring,   tags: [monitoring, grype] }
```

---

## Run 0 — Déploiement depuis zéro

### Étape 1 : VPS + variables
```bash
cd terraform/ && terraform apply        # → IP publique → inventory.ini
cp *.example → remplir → ansible-vault encrypt
```

### Étape 2 : Bootstrap
```bash
ansible-playbook -i inventory.ini playbooks/bootstrap.yml --ask-vault-pass
```

### Étape 3 : Phase 1 — Infrastructure
```bash
ansible-playbook -i inventory.ini playbooks/infrastructure.yml --ask-vault-pass
```
→ Tout le socle est UP. `mesh.domain.com` accessible.

### Étape 4 : Enrollment NetBird (MANUEL)
```bash
# Dashboard : https://mesh.domain.com → créer setup keys

# OBLIGATOIRE — machines infra
ssh lucas@<VPS> -p <PORT>
sudo netbird up --setup-key <KEY> --management-url https://mesh.domain.com
netbird status   # → IP 100.x.x.x → host_vars/vps_serv.yml

ssh lucas@<PI> -p <PORT>
sudo netbird up --setup-key <KEY> --management-url https://mesh.domain.com
netbird status   # → IP 100.x.x.x → host_vars/pi_serv.yml

# OBLIGATOIRE — au moins un device admin (avant mesh-config)
# Installer NetBird sur laptop et/ou phone

# Mettre à jour les IPs
ansible-vault edit host_vars/vps_serv.yml    # host_netbird_ip
ansible-vault edit host_vars/pi_serv.yml     # host_netbird_ip
```

### Étape 5 : Phase 2 — Services
```bash
ansible-playbook -i inventory.ini playbooks/services.yml --ask-vault-pass
ansible-playbook -i inventory.ini playbooks/mesh-config.yml --ask-vault-pass
```
→ Tous les containers UP, bind sur IP mesh. ACLs deny-by-default.

### Étape 6 : Setup Ntfy auth (automatisé par Ansible)

> Plus besoin de `docker exec` manuel.
> L'utilisateur et le token sont créés automatiquement par le rôle services-vps.
> Pré-requis : `vault_ntfy_admin_user` et `vault_ntfy_auth_token` dans le vault.

### Étape 7 : Vérifier
```bash
curl -sf https://pdf.domain.com
curl -sf https://portfolio.domain.com
# VPN : curl -sf https://vault.domain.com/alive
```

---

## Mises à jour

### Changer une version d'image
```bash
# Éditer directement sur GitHub UI ou en local :
vi group_vars/versions.yml                  # version: "X.Y.Z"
ansible-playbook playbooks/services.yml --tags services --limit lan --ask-vault-pass
```

### Publier un projet perso (termfolio, bientot, veille-secu)
```bash
cd termfolio && git tag v1.3.0 && git push origin --tags
# → GitHub Actions build → GHCR
vi group_vars/versions.yml                  # termfolio_version: "1.3.0"
ansible-playbook playbooks/services.yml --tags services --limit lan --ask-vault-pass
```

### Ajouter un service (voir aussi docs/10-ADDING-MACHINE.md)
1. Container dans `services-pi/templates/docker-compose.brain.yml.j2`
   Reseau Docker : `brain_services` (donnees utilisateur), `brain_infra` (monitoring/infra), `brain_public` (public via VPS), ou `brain_vault` (isole)
2. Secrets dans `services-pi/templates/brain.env.j2`
3. Version dans `group_vars/versions.yml`
4. Route Traefik dans `backbone/templates/traefik-services.yml.j2`
5. DNS rewrite dans `mesh-config/tasks/main.yml`
6. ACL port dans `mesh-config/tasks/main.yml` (policy infra→cerveau)
7. Relancer : `services.yml --tags services` + `infrastructure.yml --tags backbone` + `mesh-config.yml`
