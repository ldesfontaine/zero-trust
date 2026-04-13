# Cartographie des rôles

> 21 rôles, 6 playbooks. Ce document liste l'ordre d'exécution, la propriété des fichiers partagés et les dépendances implicites.

## Rôles utilitaires (pre_tasks, chargés partout)

| Rôle | Description | Utilisé dans |
|---|---|---|
| `connection-resolver` | Détection auto du contexte SSH (LAN/NetBird/local, port durci/22) | Tous les playbooks (pre_tasks) |
| `netbird-resolve` | Résout `host_netbird_ip` pour le binding Docker | Tous les playbooks (pre_tasks) |

## Par playbook et ordre d'exécution

### bootstrap.yml (L0)

Pas de rôles — tasks inline. Crée les users admin + deploy sur machines vierges.

### infrastructure.yml (L1-L3)

**Play 1 — VPS (sentinel)**

| Ordre | Rôle | Layer | Tags | Description |
|---|---|---|---|---|
| 1 | `system-vps` | L1 | `layer1, system-vps` | Paquets, nftables, hostname |
| 2 | `hardening-vps` | L1 | `layer1, hardening-vps` | SSH hardening, sysctl |
| 3 | `docker` | L2 | `layer2, docker` | Docker Engine + user deploy dans groupe docker |
| 4 | `traefik` | L3a | `layer3, traefik` | Crée sentinel_net, dossiers, config dynamique |
| 5 | `netbird-server` | L3b | `layer3, netbird-server` | Compose backbone (Traefik + NetBird server + dashboard) |
| 6 | `netbird-client` | L3c | `layer3, netbird-client` | Enrollment du client NetBird sur le VPS |

**Play 2 — Pi (brain)**

| Ordre | Rôle | Layer | Tags | Description |
|---|---|---|---|---|
| 1 | `system-pi` | L1 | `layer1, system-pi` | Paquets, UFW, hostname |
| 2 | `hardening-pi` | L1 | `layer1, hardening-pi` | SSH hardening, sysctl |
| 3 | `docker` | L2 | `layer2, docker` | Docker Engine |
| 4 | `netbird-client` | L3 | `layer3, netbird-client` | Enrollment du client NetBird sur le Pi |

### services.yml (L4)

**Play 1 — VPS**

| Ordre | Rôle | Tags | Description |
|---|---|---|---|
| 1 | `stack-vps` | `layer4, stack-vps, crowdsec, ntfy, node-exporter-vps` | Compose CrowdSec + Ntfy + node-exporter |
| 2 | `crowdsec-bouncer` | `layer4, crowdsec-bouncer, crowdsec` | Bouncer nftables sur l'hôte |

**Play 2 — Pi**

| Ordre | Rôle | Tags | Description |
|---|---|---|---|
| 1 | `stack-pi` | `layer4, stack-pi, seafile, vaultwarden, immich, adguard, bentopdf, portfolio, node-exporter-pi` | Compose complet Pi (tous les services) |
| 2 | `netbird-dns` | `layer4, netbird-dns` | Config DNS NetBird (dns_servers only) |
| 3 | `adguard-dns` | `layer4, adguard-dns` | Rewrites AdGuard + split DNS .home |
| 4 | `netbird-acl` | `layer4, netbird-acl` | Policies deny-by-default NetBird |
| 5 | `veille-secu` | `layer4, veille-secu` | Projet externe : git clone + docker compose |
| 6 | `bientot` | `layer4, bientot` | Projet externe : git clone + docker compose |

### operations.yml (L5)

**Play 1 — Pi**

| Ordre | Rôle | Tags | Description |
|---|---|---|---|
| 1 | `backup-zfs` | `layer5, backup-zfs` | Snapshots ZFS + GPG + envoi VPS + USB |
| 2 | `image-maintenance` | `layer5, image-maintenance` | Cron pull + prune + scan Trivy |
| 3 | `alerting` | `layer5, alerting` | Checks locaux → Ntfy |

**Play 2 — VPS**

| Ordre | Rôle | Tags | Description |
|---|---|---|---|
| 1 | `image-maintenance` | `layer5, image-maintenance` | Cron pull + prune + scan Trivy |
| 2 | `alerting` | `layer5, alerting` | Checks locaux → Ntfy |

### onboard.yml

Enchaîne `bootstrap.yml` + `infrastructure.yml` (L0-L3 pour nouvelle machine).

### restore.yml

Tasks inline. Restaure Vaultwarden, Seafile, Immich depuis backup VPS ou USB.

## Propriété des fichiers partagés

| Fichier déployé | Propriétaire | Consommateurs | Notes |
|---|---|---|---|
| `/opt/backbone/docker-compose.yml` | `netbird-server` | traefik (via sentinel_net) | Contient Traefik ET NetBird — nommage trompeur mais fonctionnel |
| `/opt/backbone/traefik/dynamic/*.yml` | `traefik` | Traefik (file provider) | Config dynamique : routers Pi, middlewares |
| `sentinel_net` (réseau Docker) | `traefik` | backbone + stack-vps | Créé par traefik, external dans stack-vps |
| `/opt/sentinel/docker-compose.yml` | `stack-vps` | crowdsec-bouncer (dépend de CrowdSec) | |
| `nftables.conf` | `system-vps` | hardening-vps (notify handler) | Handler `Reload nftables` dans system-vps uniquement |
| `sshd_config` (VPS) | `hardening-vps` | — | Posé L1, plus modifié |
| `sshd_config` (Pi) | `hardening-pi` | — | Posé L1, plus modifié |

## Dépendances implicites (non déclarées dans meta)

Toutes les dépendances sont gérées par **l'ordre des rôles dans les playbooks**, pas par `meta/main.yml` (évite les doubles exécutions).

| Rôle | Dépend de | Raison |
|---|---|---|
| `hardening-vps` | `system-vps` | Notifie le handler nftables de system-vps |
| `hardening-pi` | `system-pi` | Paquets système installés par system-pi |
| `netbird-server` | `traefik` | Utilise sentinel_net créé par traefik |
| `netbird-client` | `netbird-server` | Le serveur doit tourner avant l'enrollment |
| `crowdsec-bouncer` | `stack-vps` | CrowdSec LAPI doit être UP |
| `stack-pi` / `stack-vps` | `docker` | Docker Engine requis |
| `netbird-dns` / `adguard-dns` / `netbird-acl` | `stack-pi` | AdGuard doit tourner |
| `veille-secu` / `bientot` | `docker` | Docker Engine requis |
| `image-maintenance` | `docker` | Docker Engine requis |
