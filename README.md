# Homelab Zero Trust — Deploiement Ansible + Terraform

Infrastructure DevSecOps hybride : un VPS cloud (**Sentinelle**) agit comme DMZ publique, un Raspberry Pi 5 (**Cerveau**) heberge les donnees, relies par un tunnel WireGuard chiffre via NetBird mesh. Aucun port domestique ouvert sur Internet.

---

## Architecture

```
Internet
   |  80/443 (HTTPS), 33073 (NetBird gRPC), 3478 (STUN/TURN)
   v
VPS — Sentinelle (DMZ)
|
|  /opt/backbone/ (L3 — infra critique)
|  +-- Traefik v2.11        -> reverse proxy HTTPS + TLS Let's Encrypt
|  +-- NetBird Server       -> orchestrateur mesh VPN WireGuard
|  +-- NetBird Dashboard    -> UI de gestion du mesh
|
|  /opt/sentinel/ (L4 — services applicatifs)
|  +-- CrowdSec + nftables  -> IDS/IPS comportemental (DROP kernel)
|  +-- Ntfy                  -> serveur de notifications push
|  +-- node-exporter         -> metriques systeme
|
|  Les 2 stacks partagent le reseau Docker sentinel_net (external)
|
        | Tunnel WireGuard chiffre (E2E)
        v

Raspberry Pi 5 — Cerveau (LAN local, zero port ouvert)
+-- Seafile              -> cloud personnel
+-- Vaultwarden          -> gestionnaire de mots de passe
+-- Immich               -> photos/videos (~250 Go)
+-- AdGuard Home         -> DNS resolver mesh + blocage pub
+-- Portfolio (termfolio) -> site vitrine (public via VPS tunnel)
+-- Veille Secu          -> monitoring CVE/advisories (projet externe)
+-- node-exporter        -> metriques systeme
+-- Bientot              -> panel admin prive (NetBird uniquement)
```

### DNS mesh — NetBird + AdGuard

NetBird est configure pour utiliser **AdGuard Home** (Pi, port 5353) comme DNS resolver pour **tous les peers du mesh**. Quand un device rejoint le mesh, il herite automatiquement du blocage pub et des rewrites DNS internes (sous-domaines prives resolus vers les IPs NetBird).

Le role `netbird-dns` configure ca via l'API NetBird (nameserver group "AdGuard-Pi" applique au groupe "All").

### ACLs NetBird (Zero Trust)

```
admins      <-> sentinelle  : acces total (SSH, management)
admins      <-> cerveau     : acces total (SSH, services)
sentinelle   -> cerveau     : TCP 8090-8094, 3000-3001 (backends Traefik)
cerveau      -> sentinelle  : TCP 9100, 6060 (monitoring node-exporter + CrowdSec)
sentinelle  <-> cerveau     : ICMP (health checks)
Policy Default : SUPPRIMEE (deny-by-default)
```

---

## Structure du projet

```
deployVps/
+-- inventory.ini                          # Hotes cibles
+-- ansible.cfg                            # SSH keepalives, pipelining
|
+-- terraform/                             # Lifecycle VPS (Hostinger)
|   +-- main.tf                            # Provider + ressource VPS
|   +-- variables.tf                       # Plan, localisation, cle SSH
|   +-- outputs.tf                         # IP publique -> utilisee par Ansible
|   +-- terraform.tfvars.example           # Template des valeurs
|
+-- playbooks/
|   +-- bootstrap.yml                      # L0 : creation users admin + deploy
|   +-- infrastructure.yml                 # L1-L3 : systeme, hardening, Docker, backbone, mesh
|   +-- services.yml                       # L4 : stacks applicatives, CrowdSec
|   +-- operations.yml                     # L5 : backup ZFS, alerting Ntfy
|
+-- roles/
|   +-- # L1 — OS
|   +-- system-vps/                        # apt, nftables, unattended-upgrades (VPS)
|   +-- system-pi/                         # apt, UFW (Pi)
|   +-- hardening-vps/                     # SSH durci VPS (Ed25519, port custom)
|   +-- hardening-pi/                      # SSH durci Pi (Ed25519, port custom)
|   +-- # L2 — Runtime
|   +-- docker/                            # Docker Engine (amd64 + arm64)
|   +-- # L3 — Backbone reseau + mesh
|   +-- traefik/                           # Reverse proxy + TLS (/opt/backbone/, VPS only)
|   +-- netbird-server/                    # Serveur mesh + dashboard (/opt/backbone/, VPS only)
|   +-- netbird-client/                    # Client NetBird (toutes machines)
|   +-- netbird-dns/                       # AdGuard comme DNS resolver NetBird (API)
|   +-- netbird-acl/                       # Groupes + policies ACL Zero Trust
|   +-- netbird-resolve/                   # Calcul netbird_bind_ip par host
|   +-- connection-resolver/               # Detection auto connexion/route/port SSH
|   +-- adguard-dns/                       # DNS rewrites AdGuard -> services Pi
|   +-- # L4 — Services
|   +-- stack-vps/                         # CrowdSec, Ntfy, node-exporter (/opt/sentinel/)
|   +-- stack-pi/                          # Seafile, Vaultwarden, Immich, AdGuard, etc.
|   +-- crowdsec-bouncer/                  # Bouncer nftables VPS
|   +-- veille-secu/                       # Projet externe (git clone + docker compose)
|   +-- bientot/                           # Projet externe (git clone + docker compose)
|   +-- # L5 — Operations
|   +-- backup-zfs/                        # Snapshots + exports chiffres GPG
|   +-- alerting/                          # Health checks -> Ntfy
|
+-- group_vars/
|   +-- all.yml                            # Versions images, domaine, sous-domaines
|
+-- host_vars/
|   +-- vps_serv.yml                       # Secrets VPS (ansible-vault)
|   +-- pi_serv.yml                        # Secrets Pi (ansible-vault)
|
+-- .github/workflows/
|   +-- deploy.yml                         # workflow_dispatch (deploy manuel)
|
+-- docs/
    +-- deploy-ARCHITECTURE.md             # Architecture complete
    +-- BOOTSTRAP.md                       # Procedure Run 0 pas a pas
    +-- ADDING-MACHINE.md                  # Comment onboard une nouvelle machine
    +-- DISASTER-RECOVERY.md               # Tout est mort, comment reconstruire
    +-- SECRETS.md                         # Gestion des secrets (vault + GitHub)
    +-- SWITCH-VLAN.md                     # Config VLAN Netgear MS305E
```

---

## Prerequis

```bash
# Ansible >= 2.14
pip install ansible

# Collections requises
ansible-galaxy collection install ansible.posix

# Cle SSH Ed25519 dediee
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_vps_homelab

# Terraform >= 1.5 (pour le VPS)
# https://developer.hashicorp.com/terraform/install
```

---

## Configuration

### `group_vars/all.yml`

Configuration partagee (pas de secrets). Voir `group_vars/all.yml.example`.

Variables cles :
- Versions des images Docker
- Domaine de base et sous-domaines
- IPs NetBird (renseignees apres enrollment)

### `host_vars/vps_serv.yml` et `host_vars/pi_serv.yml`

Secrets par machine. Voir les `.example`. Chiffrer avec `ansible-vault encrypt`.

### DNS A records

Tous les sous-domaines doivent pointer vers l'IP publique du VPS :

```
mesh.ton-domaine.com      -> IP_VPS   (NetBird)
pdf.ton-domaine.com       -> IP_VPS   (BentoPDF, public)
portfolio.ton-domaine.com -> IP_VPS   (Portfolio, public via tunnel)
cloud.ton-domaine.com     -> IP_VPS   (Seafile, prive)
vault.ton-domaine.com     -> IP_VPS   (Vaultwarden, prive)
adguard.ton-domaine.com   -> IP_VPS   (AdGuard, prive)
photos.ton-domaine.com    -> IP_VPS   (Immich, prive)
ntfy.ton-domaine.com      -> IP_VPS   (Ntfy)
bientot.ton-domaine.com   -> IP_VPS   (Bientot, prive)
```

---

## Deploiement depuis zero (Run 0)

> Procedure complete : voir `docs/BOOTSTRAP.md`

### Etape 1 — Creer le VPS

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# Remplir : API token Hostinger, cle SSH publique
terraform init && terraform apply
# Output -> IP publique -> mettre dans inventory.ini
```

### Etape 2 — Bootstrap (L0 — users + SSH)

```bash
ansible-playbook -i inventory.ini playbooks/bootstrap.yml --limit dmz --ask-vault-pass
ansible-playbook -i inventory.ini playbooks/bootstrap.yml --limit lan --ask-vault-pass
```

### Etape 3 — Infrastructure VPS (L1-L3 — systeme + backbone)

```bash
ansible-playbook -i inventory.ini playbooks/infrastructure.yml --limit vps_serv --ask-vault-pass
```

Ca deploie dans l'ordre :
- L1 : systeme + hardening (nftables, SSH durci)
- L2 : Docker
- L3a : **Traefik** (reverse proxy dans `/opt/backbone/`)
- L3b : **NetBird server + dashboard** (dans `/opt/backbone/`)
- L3c : NetBird client (daemon installe, PAS enrole)

### Etape 4 — Enrollment NetBird (MANUEL)

Le dashboard est accessible sur `https://mesh.ton-domaine.com`.

```bash
# Creer 2 setup keys (VPS + Pi) dans le dashboard

# Enroler le VPS
ssh lucas@<VPS_IP>
sudo netbird up --setup-key <KEY_VPS> --management-url https://mesh.ton-domaine.com
netbird status   # noter l'IP 100.x.x.x -> mettre dans host_vars/vps_serv.yml
```

### Etape 5 — Infrastructure Pi (L1-L3)

```bash
ansible-playbook -i inventory.ini playbooks/infrastructure.yml --limit pi_serv --ask-vault-pass
```

Puis enroler le Pi :

```bash
ssh lucas@<PI_IP>
sudo netbird up --setup-key <KEY_PI> --management-url https://mesh.ton-domaine.com
netbird status   # noter l'IP 100.x.x.x -> mettre dans host_vars/pi_serv.yml
```

### Etape 5b — Enroler le laptop/phone dans NetBird (AVANT services.yml)

> **Obligatoire** : le role `netbird-acl` refuse de supprimer la policy Default
> s'il ne detecte aucun peer admin (= ni VPS, ni Pi). Sans peer admin, la suppression
> vous couperait tout acces au mesh sans possibilite de recovery.

```bash
# Installer le client NetBird sur le laptop
# https://docs.netbird.io/how-to/installation

# L'enroler dans le mesh
netbird up --setup-key <KEY_LAPTOP> --management-url https://mesh.ton-domaine.com
netbird status   # verifier la connexion au mesh
```

Une fois le laptop visible comme peer dans le dashboard NetBird, `services.yml` pourra
configurer les ACLs Zero Trust.

### Etape 6 — Services (L4)

```bash
# Les deux plays tournent dans le meme playbook (VPS puis Pi)
ansible-playbook playbooks/services.yml --diff --ask-vault-pass
```

Le role `netbird-dns` configure automatiquement AdGuard comme DNS resolver pour tout le mesh NetBird.
Le role `netbird-acl` applique les policies Zero Trust (deny-by-default).

### Etape 7 — Operations (L5)

```bash
ansible-playbook -i inventory.ini playbooks/operations.yml --ask-vault-pass
```

### Etape 8 — Configurer GitHub Secrets pour la CI

```
ANSIBLE_VAULT_PASSWORD   -> passphrase du vault
SSH_PRIVATE_KEY          -> cle du user deploy (PAS admin)
```

A partir de la, tout deploiement passe par `workflow_dispatch` dans GitHub Actions.

---

## Operations courantes (post-Run 0)

### Mettre a jour un seul service

```bash
# Mettre a jour Seafile
ansible-playbook -i inventory.ini playbooks/services.yml --tags stack-pi --limit pi_serv

# Mettre a jour CrowdSec
ansible-playbook -i inventory.ini playbooks/services.yml --tags stack-vps --limit vps_serv

# Mettre a jour le bouncer nftables
ansible-playbook -i inventory.ini playbooks/services.yml --tags crowdsec-bouncer --limit vps_serv

# Mettre a jour la veille secu
ansible-playbook -i inventory.ini playbooks/services.yml --tags veille-secu --limit pi_serv

# Mettre a jour Bientot
ansible-playbook -i inventory.ini playbooks/services.yml --tags bientot --limit pi_serv
```

### Mettre a jour le backbone (Traefik / NetBird server)

```bash
# Attention : toucher au backbone impacte TOUS les services
ansible-playbook -i inventory.ini playbooks/infrastructure.yml --tags traefik --limit vps_serv
ansible-playbook -i inventory.ini playbooks/infrastructure.yml --tags netbird-server --limit vps_serv
```

### Mettre a jour les ACLs ou le DNS mesh

```bash
# ACLs NetBird (policies Zero Trust)
ansible-playbook -i inventory.ini playbooks/services.yml --tags netbird-acl --limit pi_serv

# DNS NetBird (AdGuard comme resolver mesh)
ansible-playbook -i inventory.ini playbooks/services.yml --tags netbird-dns --limit pi_serv

# Rewrites DNS AdGuard (sous-domaines prives -> IPs NetBird)
ansible-playbook -i inventory.ini playbooks/services.yml --tags adguard-dns --limit pi_serv
```

### Relancer tout un layer

```bash
# Tout le layer reseau (L3)
ansible-playbook -i inventory.ini playbooks/infrastructure.yml --tags layer3

# Tous les services (L4)
ansible-playbook -i inventory.ini playbooks/services.yml

# Juste les operations (L5)
ansible-playbook -i inventory.ini playbooks/operations.yml
```

### Dry-run (ne change rien, montre les diffs)

```bash
ansible-playbook -i inventory.ini playbooks/services.yml --check --diff
```

### Via GitHub Actions (CI/CD)

Aller dans Actions > deploy.yml > Run workflow :
- **playbook** : `infrastructure`, `services`, ou `operations`
- **tags** : vide (tout) ou specifique (`seafile`, `traefik`, `backup`...)
- **limit** : vide (tout) ou specifique (`vps_serv`, `pi_serv`)
- **mode** : `check` (dry-run) ou `apply` (deploiement reel)

Le VPS est le bastion — le connection-resolver detecte automatiquement le mode de connexion (local sur le VPS, SSH+NetBird vers le Pi). Plus besoin de `ci_mode`.

---

## Services

### Services publics (sans VPN)

| URL | Service |
|-----|---------|
| `https://pdf.ton-domaine.com` | BentoPDF |
| `https://portfolio.ton-domaine.com` | Portfolio |

### Services prives (client NetBird requis)

| URL | Service |
|-----|---------|
| `https://cloud.ton-domaine.com` | Seafile |
| `https://vault.ton-domaine.com` | Vaultwarden |
| `https://photos.ton-domaine.com` | Immich |
| `https://adguard.ton-domaine.com` | AdGuard Home |
| `https://bientot.ton-domaine.com` | Bientot (panel admin) |

### Services VPS

| URL | Service |
|-----|---------|
| `https://mesh.ton-domaine.com` | Dashboard NetBird |
| `https://ntfy.ton-domaine.com` | Notifications push |

---

## Backup — Strategie 3-2-1

| Copie | Support | Contenu | Chiffrement |
|-------|---------|---------|-------------|
| 1 | ZFS mirror (Pi) | Tout | Non (protection hardware) |
| 2 | SSD USB air-gapped | Tout (snapshot ZFS complet) | LUKS |
| 3 | VPS (off-site, 100 Go) | Donnees critiques | GPG asymetrique |

Chaque role declare ses donnees via `backup.yml`. Le cron les detecte automatiquement.

---

## Ports exposes

### VPS (Internet)

| Port | Proto | Service |
|------|-------|---------|
| 2222 | TCP | SSH (cle Ed25519 uniquement) |
| 80 | TCP | HTTP (redirect HTTPS via Traefik) |
| 443 | TCP | HTTPS (Traefik -> services) |
| 33073 | TCP | NetBird Management API |
| 3478 | TCP/UDP | NetBird STUN/TURN |

### Pi (LAN local uniquement)

| Port | Bind | Service |
|------|------|---------|
| 2223 | `0.0.0.0` | SSH (cle Ed25519 uniquement) |
| 8090 | IP NetBird | BentoPDF |
| 8091 | IP NetBird | Portfolio |
| 8092 | IP NetBird | Seafile |
| 8093 | IP NetBird | Vaultwarden |
| 8094 | IP NetBird | Immich |
| 3000 | IP NetBird | AdGuard Home UI |
| 5353 | IP NetBird | AdGuard DNS (UDP/TCP) |
| 9100 | IP NetBird | Node Exporter |

---

## Securite

- Tous les secrets dans `host_vars/` chiffres avec `ansible-vault`
- `group_vars/all.yml` ne contient aucun secret
- Firewall VPS : **nftables natif** (pas UFW) — CrowdSec bouncer injecte dans nftables
- Firewall Pi : **UFW** (pas de CrowdSec sur le Pi)
- SSH : cle Ed25519, password desactive, port custom, root desactive
- ACLs NetBird : deny-by-default, policy Default supprimee
- DNS mesh : tous les peers utilisent AdGuard via NetBird (blocage pub + rewrites internes)

---

## Troubleshooting

### "Unable to reach one or more DNS servers" (notif NetBird sur le laptop)

**Cause** : le playbook a redeploye ou redemmarre AdGuard Home sur le Pi. Comme AdGuard est le DNS resolver du mesh NetBird (configure par `netbird-dns`), tous les peers perdent la resolution DNS pendant les 2-3 secondes du restart.

**Resolution** : temporaire et auto-resolu. Une fois AdGuard remonte, le DNS revient. Si la notif persiste, verifier que le container AdGuard tourne (`docker ps` sur le Pi) et que le port 5353 est bien expose sur l'IP NetBird.

### netbird-acl echoue : "Aucun peer admin trouve"

**Cause** : le role `netbird-acl` exige au moins un peer admin (ni VPS, ni Pi) avant de toucher aux ACLs. C'est une securite pour eviter un lockout du mesh.

**Resolution** : enroler au moins un client NetBird (laptop, phone) dans le mesh, puis relancer :

```bash
ansible-playbook playbooks/services.yml --diff --ask-vault-pass --tags netbird-acl
```

### "Lancement de la Stack" affiche changed a chaque run

**Cause** : `docker compose up -d` rapporte changed des qu'il recree un container (meme config). C'est normal si un template ou une image a change dans le meme run. Si changed apparait sans autre changement en amont, verifier les labels/env dans le template docker-compose.

---

## Documentation

| Document | Contenu |
|----------|---------|
| `docs/deploy-ARCHITECTURE.md` | Architecture complete et decisions |
| `docs/BOOTSTRAP.md` | Procedure Run 0 pas a pas |
| `docs/ADDING-MACHINE.md` | Onboard une nouvelle machine |
| `docs/DISASTER-RECOVERY.md` | Reconstruire de zero |
| `docs/SECRETS.md` | Gestion des secrets |
| `docs/SWITCH-VLAN.md` | Config VLAN Netgear MS305E |
