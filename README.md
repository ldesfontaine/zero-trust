# Homelab Zero Trust — Déploiement Ansible + Terraform

Infrastructure DevSecOps hybride : un VPS cloud (**Sentinelle**) agit comme DMZ publique, un Raspberry Pi 5 (**Cerveau**) héberge les données, reliés par un tunnel WireGuard chiffré via NetBird mesh. Aucun port domestique ouvert sur Internet.

---

## Architecture

```
Internet
   │  80/443 (HTTPS), 33073 (NetBird gRPC), 3478 (STUN/TURN)
   ▼
VPS — Sentinelle (DMZ)
├── Traefik v2.11          → reverse proxy HTTPS + TLS Let's Encrypt
├── CrowdSec + nftables    → IDS/IPS comportemental (DROP kernel)
├── NetBird Server         → orchestrateur mesh VPN WireGuard
├── Ntfy                   → serveur de notifications push
├── BentoPDF               → outil PDF (public, stateless)
└── node-exporter          → métriques système

        ║ Tunnel WireGuard chiffré (E2E)
        ▼

Raspberry Pi 5 — Cerveau (LAN local, zéro port ouvert)
├── Seafile              → cloud personnel
├── Vaultwarden            → gestionnaire de mots de passe
├── Immich                 → photos/vidéos (~250 Go)
├── AdGuard Home           → DNS resolver mesh + blocage pub
├── Portfolio (termfolio)  → site vitrine (public via VPS tunnel)
├── Veille Sécu            → monitoring CVE/advisories (projet externe)
├── node-exporter          → métriques système (scrappé par Bientôt)
└── Bientôt                → panel admin privé : monitoring + alerting (NetBird uniquement)
```

### Réseaux Docker sur le Pi

```
brain_public   → BentoPDF, Portfolio  (accessibles publiquement via VPS proxy)
brain_private  → Seafile, Vaultwarden, Immich, AdGuard (VPN NetBird requis)
```

### ACLs NetBird (Zero Trust)

```
admins      ↔ sentinelle  : accès total (SSH, management)
admins      ↔ cerveau     : accès total (SSH, services)
sentinelle  → cerveau     : TCP 8090-8094, 3000-3001 (backends Traefik)
cerveau     → sentinelle  : TCP 9100, 6060 (monitoring node-exporter + CrowdSec)
sentinelle  ↔ cerveau     : ICMP (health checks)
Policy Default : SUPPRIMÉE (deny-by-default)
```

---

## Structure du projet

```
deployVps/
├── inventory.ini                          # Hôtes cibles
├── setup.yml                              # Playbook principal (importe les 4 playbooks)
├── ansible.cfg                            # SSH keepalives, pipelining
│
├── terraform/                             # Lifecycle VPS (Hostinger)
│   ├── main.tf                            # Provider + ressource VPS
│   ├── variables.tf                       # Plan, localisation, clé SSH
│   ├── outputs.tf                         # IP publique → utilisée par Ansible
│   └── terraform.tfvars.example           # Template des valeurs
│
├── playbooks/
│   ├── bootstrap.yml                      # L0 : création users admin
│   ├── infrastructure.yml                 # L1-L3 : système, hardening, Docker, mesh
│   ├── services.yml                       # L4 : stacks applicatives, CrowdSec
│   ├── operations.yml                     # L5 : backup ZFS, alerting Ntfy
│   ├── onboard.yml                        # L0-L3 : provisionnement nouvelle machine
│   └── restore.yml                        # Restauration depuis backup VPS ou USB
│
├── roles/
│   ├── system-vps/                        # L1 : apt, nftables, unattended-upgrades (VPS)
│   ├── system-pi/                         # L1 : apt, UFW (Pi)
│   ├── hardening-vps/                     # L1 : SSH durci VPS (Ed25519, port custom)
│   ├── hardening-pi/                      # L1 : SSH durci Pi (Ed25519, port custom)
│   ├── docker/                            # L2 : Docker Engine (amd64 + arm64)
│   ├── netbird-client/                    # L3 : installation client NetBird
│   ├── netbird-dns/                       # L3 : AdGuard comme DNS resolver NetBird
│   ├── netbird-acl/                       # L3 : groupes + policies ACL Zero Trust
│   ├── adguard-dns/                       # L3 : DNS rewrites AdGuard → services Pi
│   ├── stack-vps/                         # L4 : Traefik, CrowdSec, NetBird Server, Ntfy, node-exporter
│   ├── stack-pi/                          # L4 : Seafile, Vaultwarden, Immich, AdGuard, BentoPDF, Portfolio
│   ├── crowdsec-bouncer/                  # L4 : bouncer nftables VPS
│   ├── veille-secu/                       # L4 : projet externe (git clone + docker compose)
│   ├── bientot/                           # L4 : projet externe (git clone + docker compose)
│   ├── backup-zfs/                        # L5 : snapshots + exports chiffrés GPG
│   └── alerting/                          # L5 : health checks → Ntfy
│
├── group_vars/
│   └── all.yml                            # Versions images, domaine, sous-domaines, IPs NetBird
│
├── host_vars/
│   ├── vps_serv.yml                       # Secrets VPS  ← chiffrer avec ansible-vault
│   └── pi_serv.yml                        # Secrets Pi   ← chiffrer avec ansible-vault
│
├── .github/workflows/
│   ├── ci.yml                             # Lint + syntax-check sur push/PR
│   └── deploy.yml                         # workflow_dispatch (deploy manuel)
│
└── docs/
    ├── deploy-ARCHITECTURE.md             # Architecture complète
    ├── BOOTSTRAP.md                       # Procédure Run 0 pas à pas
    ├── ADDING-MACHINE.md                  # Comment onboard une nouvelle machine
    ├── DISASTER-RECOVERY.md               # Tout est mort, comment reconstruire
    ├── SECRETS.md                         # Gestion des secrets (vault + GitHub)
    └── SWITCH-VLAN.md                     # Config VLAN Netgear MS305E
```

---

## Prérequis

```bash
# Ansible >= 2.14
pip install ansible

# Collections requises
ansible-galaxy collection install ansible.posix

# Clé SSH Ed25519 dédiée
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_vps_homelab

# Terraform >= 1.5 (pour le VPS)
# https://developer.hashicorp.com/terraform/install
```

---

## Configuration

### `group_vars/all.yml`

Configuration partagée (pas de secrets). Voir `group_vars/all.yml.example`.

Variables clés :
- Versions des images Docker
- Domaine de base et sous-domaines
- IPs NetBird (renseigner après enrollment)

### `host_vars/vps_serv.yml` et `host_vars/pi_serv.yml`

Secrets par machine. Voir les `.example`. Chiffrer avec `ansible-vault encrypt`.

### DNS A records

Tous les sous-domaines doivent pointer vers l'IP publique du VPS :

```
mesh.ton-domaine.com      → IP_VPS   (NetBird)
pdf.ton-domaine.com       → IP_VPS   (BentoPDF, public)
portfolio.ton-domaine.com → IP_VPS   (Portfolio, public via tunnel)
cloud.ton-domaine.com     → IP_VPS   (Seafile, privé)
vault.ton-domaine.com     → IP_VPS   (Vaultwarden, privé)
adguard.ton-domaine.com   → IP_VPS   (AdGuard, privé)
photos.ton-domaine.com    → IP_VPS   (Immich, privé)
ntfy.ton-domaine.com      → IP_VPS   (Ntfy)
bientot.ton-domaine.com   → IP_VPS   (Bientôt, privé)
```

---

## Déploiement

### Run 0 — Bootstrap (local, une seule fois)

```bash
# 1. Créer le VPS
cd terraform/ && terraform apply

# 2. Bootstrap + infrastructure
ansible-playbook -i inventory.ini playbooks/bootstrap.yml --ask-vault-pass
ansible-playbook -i inventory.ini playbooks/infrastructure.yml --ask-vault-pass
```

Puis enrollment NetBird manuel + renseigner les IPs dans les variables.
Voir `docs/BOOTSTRAP.md` pour la procédure complète.

### Run 1+ — Via GitHub Actions (workflow_dispatch)

Paramètres : playbook (infrastructure/services/operations), tags, limit, mode (check/apply).

Le VPS est le bastion — GitHub Actions SSH vers le VPS, le VPS relaye vers le Pi via NetBird.

### Déploiement complet

```bash
ansible-playbook -i inventory.ini setup.yml --ask-vault-pass
```

---

## Services

### Services publics (sans VPN)

| URL | Service |
|-----|---------|
| `https://pdf.ton-domaine.com` | BentoPDF |
| `https://portfolio.ton-domaine.com` | Portfolio |

### Services privés (client NetBird requis)

| URL | Service |
|-----|---------|
| `https://cloud.ton-domaine.com` | Seafile |
| `https://vault.ton-domaine.com` | Vaultwarden |
| `https://photos.ton-domaine.com` | Immich |
| `https://adguard.ton-domaine.com` | AdGuard Home |
| `https://bientot.ton-domaine.com` | Bientôt (panel admin) |

### Services VPS

| URL | Service |
|-----|---------|
| `https://mesh.ton-domaine.com` | Dashboard NetBird |
| `https://ntfy.ton-domaine.com` | Notifications push |

---

## Backup — Stratégie 3-2-1

| Copie | Support | Contenu | Chiffrement |
|-------|---------|---------|-------------|
| 1 | ZFS mirror (Pi) | Tout | Non (protection hardware) |
| 2 | SSD USB air-gapped | Tout (snapshot ZFS complet) | LUKS |
| 3 | VPS (off-site, 100 Go) | Données critiques | GPG asymétrique |

Chaque rôle déclare ses données via `backup.yml`. Le cron les détecte automatiquement.

---

## Ports exposés

### VPS (Internet)

| Port | Proto | Service |
|------|-------|---------|
| 2222 | TCP | SSH (clé Ed25519 uniquement) |
| 80 | TCP | HTTP (redirect HTTPS via Traefik) |
| 443 | TCP | HTTPS (Traefik → services) |
| 33073 | TCP | NetBird Management API |
| 3478 | TCP/UDP | NetBird STUN/TURN |

### Pi (LAN local uniquement)

| Port | Bind | Service |
|------|------|---------|
| 2223 | `0.0.0.0` | SSH (clé Ed25519 uniquement) |
| 8090 | IP NetBird | BentoPDF |
| 8091 | IP NetBird | Portfolio |
| 8092 | IP NetBird | Seafile |
| 8093 | IP NetBird | Vaultwarden |
| 8094 | IP NetBird | Immich |
| 3000 | IP NetBird | AdGuard Home UI |
| 5353 | IP NetBird | AdGuard DNS (UDP/TCP) |
| 9100 | IP NetBird | Node Exporter |

---

## Sécurité

- Tous les secrets dans `host_vars/` chiffrés avec `ansible-vault`
- `group_vars/all.yml` ne contient aucun secret
- Firewall VPS : **nftables natif** (pas UFW) — CrowdSec bouncer injecte dans nftables
- Firewall Pi : **UFW** (pas de CrowdSec sur le Pi)
- SSH : clé Ed25519, password désactivé, port custom, root désactivé
- ACLs NetBird : deny-by-default, policy Default supprimée

---

## Documentation

| Document | Contenu |
|----------|---------|
| `docs/deploy-ARCHITECTURE.md` | Architecture complète et décisions |
| `docs/BOOTSTRAP.md` | Procédure Run 0 pas à pas |
| `docs/ADDING-MACHINE.md` | Onboard une nouvelle machine |
| `docs/DISASTER-RECOVERY.md` | Reconstruire de zéro |
| `docs/SECRETS.md` | Gestion des secrets |
| `docs/SWITCH-VLAN.md` | Config VLAN Netgear MS305E |
