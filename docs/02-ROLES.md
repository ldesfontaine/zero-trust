# 02 — Rôles, tags et dépendances

## Structure

```
roles/
├── common/                 ← Packages, upgrades (VPS + Pi)
├── base-vps/               ← nftables + SSH durci
├── base-pi/                ← UFW + SSH durci
├── docker/                 ← Docker Engine (amd64 + arm64)
├── backbone/               ← Traefik + NetBird server (VPS)
├── netbird-client/         ← Client NetBird + resolve IP
├── mesh-config/            ← API NetBird : ACL, DNS, groupes
├── services-vps/           ← CrowdSec + bouncer + Ntfy + bientot-agent
├── services-pi/            ← Tous les containers Pi
├── backup/                 ← ZFS snapshots + GPG + USB
├── monitoring/             ← Health checks + Trivy + alerting Ntfy
└── connection-resolver/    ← Détection auto connexion SSH
```

**12 rôles.**

---

## Tags et dépendances

### Phase 1 — infrastructure.yml

| Rôle | Tags | Machine | Dépend de (doit être UP) |
|------|------|---------|--------------------------|
| common | `common` | VPS + Pi | bootstrap (user admin existe) |
| base-vps | `base`, `hardening`, `nftables`, `ssh` | VPS | common |
| base-pi | `base`, `hardening`, `ufw`, `ssh` | Pi | common |
| docker | `docker` | VPS + Pi | base-* (firewall AVANT Docker) |
| backbone | `backbone`, `traefik`, `netbird-server` | VPS | docker, base-vps (nftables autorise 80/443/3478) |
| netbird-client | `netbird-client` | VPS + Pi | backbone (serveur NetBird doit tourner) |

**Pourquoi cet ordre :**
- `base-*` AVANT `docker` : si Docker s'installe avant le firewall, il ouvre des ports sans protection
- `backbone` APRÈS `docker` : a besoin de Docker Engine + du réseau `sentinel_net`
- `netbird-client` APRÈS `backbone` : le serveur NetBird doit être UP pour que les clients s'y connectent

### Phase 2 — services.yml

| Rôle | Tags | Machine | Dépend de (doit être UP) |
|------|------|---------|--------------------------|
| services-vps | `services`, `crowdsec`, `ntfy`, `bientot-agent` | VPS | docker, backbone (sentinel_net), netbird enrollé (mesh pour agent push) |
| services-pi | `services`, `seafile`, `vaultwarden`, `immich`, `adguard`, `bientot`, `veille-secu`, `portfolio` | Pi | docker, netbird enrollé (bind IP mesh) |
| backup | `backup`, `zfs` | Pi | services-pi (dossiers données doivent exister), mesh UP (SCP vers VPS) |
| monitoring | `monitoring`, `alerting`, `trivy` | VPS + Pi | services-* (containers à checker), Ntfy accessible (mesh UP pour le Pi) |

### Phase 2 — mesh-config.yml

| Rôle | Tags | Machine | Dépend de (doit être UP) |
|------|------|---------|--------------------------|
| mesh-config | `mesh`, `acl`, `dns` | delegate_to: localhost | backbone (API NetBird), services-pi (AdGuard doit tourner), ≥1 peer admin enrôlé |

### Utilitaire (pre_task)

| Rôle | Tags | Machine | Dépend de |
|------|------|---------|-----------|
| connection-resolver | `always` | VPS + Pi | Rien (c'est lui qui détecte comment se connecter) |

---

## Utilisation des tags

### Cibler un composant spécifique
```bash
# Uniquement CrowdSec + bouncer
ansible-playbook playbooks/services.yml --tags crowdsec --limit dmz

# Uniquement les services Pi
ansible-playbook playbooks/services.yml --tags services --limit lan

# Uniquement Traefik (config dynamique + backbone)
ansible-playbook playbooks/infrastructure.yml --tags backbone --limit dmz

# Uniquement backup
ansible-playbook playbooks/services.yml --tags backup --limit lan
```

### ⚠️ Règles de dépendance des tags

Si tu utilises `--tags`, le playbook ne lance QUE les tasks avec ce tag. Les dépendances ne sont PAS relancées automatiquement. Le prérequis doit déjà être UP.

| Tu fais `--tags X` | Il faut que Y soit déjà déployé |
|---------------------|--------------------------------|
| `--tags backbone` | docker (Engine installé) |
| `--tags services` | docker + backbone + netbird enrollé |
| `--tags crowdsec` | docker + backbone (sentinel_net) |
| `--tags seafile` | docker + netbird enrollé (bind IP mesh) |
| `--tags backup` | services-pi (dossiers données) + mesh UP |
| `--tags monitoring` | services-* + Ntfy accessible |
| `--tags mesh` | backbone + services-pi (AdGuard) + peer admin |

**En cas de doute, relancer le playbook complet sans `--tags`.**

---

## Détail par rôle

### `common`
**Machines :** VPS + Pi
```
tasks: apt update/upgrade, reset_connection, packages (curl git gnupg python3-pip cron jq), unattended-upgrades
```

### `base-vps`
**Machine :** VPS — fusionne `system-vps` + `hardening-vps`
```
possède:  templates/nftables.conf.j2, templates/sshd_config.j2
          handlers/main.yml (reload nftables + restart bouncer)
tasks:    désactiver UFW, déployer nftables (4 ports), déployer sshd (AllowTcpForwarding no),
          restart SSH async, fermer port 22 (flag facts.d), symlinks Ansible venv
```

### `base-pi`
**Machine :** Pi — fusionne `system-pi` + `hardening-pi`
```
possède:  templates/sshd_config.j2, handlers/main.yml
tasks:    UFW allow SSH + deny DNS, déployer sshd, restart SSH async,
          désactiver avahi, activer UFW, supprimer port 22
```

### `docker`
**Machines :** VPS + Pi — **inchangé**
```
tasks:    clé GPG Docker, dépôt apt, installer docker-ce + compose,
          daemon.json (DNS adaptés), ajouter users au groupe docker
ajout:    log rotation dans daemon.json :
          "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}
```

### `backbone`
**Machine :** VPS — fusionne `traefik` + `netbird-server`
```
possède:  templates/docker-compose.backbone.yml.j2 (Traefik + NetBird server + dashboard)
          templates/traefik-services.yml.j2 (middlewares + routes Pi)
          templates/netbird_config.yaml.j2
          handlers/main.yml (reload backbone)
tasks:    créer sentinel_net, arborescence /opt/backbone/, migration données,
          déployer configs, docker compose up, valider gRPC + API

middlewares dans traefik-services.yml.j2 :
  security-headers  → TOUS les routers
  netbird-only      → routers VPN-only
  rate-limit-public → routers publics (PDF, Portfolio)
  Ntfy              → security-headers uniquement (public, auth par token Ntfy)
```

### `netbird-client`
**Machines :** VPS + Pi — fusionne `netbird-client` + `netbird-resolve`
```
possède:  tasks/main.yml (installation + enrollment info)
          tasks/resolve.yml (calcul netbird_bind_ip, netbird_mesh_ready)
tasks:    installer NetBird, activer daemon, protection DNS resolv.conf
resolve:  vérifier IP sur interface (retries), produire facts binding
```

### `mesh-config`
**Exécution :** delegate_to: localhost — fusionne `netbird-acl` + `netbird-dns` + `adguard-dns`
```
tasks:    récupérer peers, créer groupes (sentinelle, cerveau, admins, infra),
          5 policies ACL, supprimer Default (guard anti-lockout),
          DNS resolver NetBird (AdGuard), DNS rewrites AdGuard
```

### `services-vps`
**Machine :** VPS — fusionne `stack-vps` + `crowdsec-bouncer`
```
possède:  templates/docker-compose.sentinel.yml.j2
          templates/sentinel.env.j2 (mode 0600)
          templates/acquis.yaml.j2
          templates/crowdsec-bouncer.yaml.j2
          templates/crowdsec-admin-whitelist.yaml.j2 (whitelist IP admin)
          handlers/main.yml
containers: crowdsec, ntfy (public + auth), node-exporter (127.0.0.1), bientot-agent
bouncer:    crowdsec-firewall-bouncer-nftables (apt, systemd, hôte)
```

### `services-pi`
**Machine :** Pi — remplace `stack-pi` + `bientot` + `veille-secu`
```
possède:  templates/docker-compose.brain.yml.j2
          templates/brain.env.j2 (mode 0600)
          templates/adguardhome.yaml.j2
          handlers/main.yml
containers: bentopdf, portfolio, seafile+db+memcached, vaultwarden (brain_vault),
            immich+db+redis, adguard, bientot-server, bientot-agent, veille-secu, node-exporter
TOUTES les images sont pull (GHCR/Docker Hub). AUCUN git clone, AUCUN docker build.
```

### `backup`
**Machine :** Pi — renommé de `backup-zfs`
```
possède:  templates/zfs-auto-snapshot.sh.j2, backup-vps.sh.j2, backup-usb.sh.j2
          templates/99-backup-usb.rules.j2, files/backup-gpg-public.asc
ajout:    trap ERR → notification Ntfy en cas d'échec (pas seulement succès)
          Bientôt DB ajouté aux données backupées
          Tous les curl Ntfy avec Authorization: Bearer
```

### `monitoring`
**Machines :** VPS + Pi — fusionne `alerting` + `image-maintenance`
```
possède:  templates/health-check.sh.j2, templates/image-maintenance.sh.j2
          defaults/main.yml (seuils)
ajout:    Trivy en --format json + jq (plus de grep regex)
          Tous les curl Ntfy avec Authorization: Bearer
          Seuil disk VPS à 80% (au lieu de 90%)
```

### `connection-resolver`
**Machines :** VPS + Pi (pre_task) — **inchangé**
```
Cascade : local → LAN → NetBird → fail
Produit : ansible_connection, ansible_host, ansible_port, ansible_user
```

---

## Matrice rôles × machines

| Rôle | Sentinelle | Cerveau | Phase |
|------|:----------:|:-------:|-------|
| connection-resolver | ✓ | ✓ | pre_task |
| common | ✓ | ✓ | 1 |
| base-vps | ✓ | | 1 |
| base-pi | | ✓ | 1 |
| docker | ✓ | ✓ | 1 |
| backbone | ✓ | | 1 |
| netbird-client | ✓ | ✓ | 1 |
| services-vps | ✓ | | 2 |
| services-pi | | ✓ | 2 |
| backup | | ✓ | 2 |
| monitoring | ✓ | ✓ | 2 |
| mesh-config | | ✓* | 2 (*delegate_to: localhost) |

---

## Graphe de dépendances

```
bootstrap
    │
    ▼
common
    │
    ├──────────────────┐
    ▼                  ▼
base-vps           base-pi
    │                  │
    ▼                  ▼
docker             docker
    │                  │
    ▼                  │
backbone               │
    │                  │
    ▼                  ▼
netbird-client     netbird-client
    │                  │
    ╠══════════════════╝
    ║
    ║  ⚠️ ENROLLMENT MANUEL
    ║
    ╠══════════════════╗
    │                  │
    ▼                  ▼
services-vps       services-pi
    │                  │
    │                  ├──► backup
    │                  │
    ├──────────────────┤
    ▼                  ▼
monitoring         monitoring
                       │
                       ▼
                  mesh-config (en dernier, besoin de tout)
```
