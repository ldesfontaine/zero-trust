# Zero Trust Homelab

Deployment Ansible pour une infrastructure personnelle Zero Trust sur 2 machines.

## Architecture

```
                     Internet
                        │
                ┌───────┴────────┐
                │  SENTINELLE    │  VPS Debian 12 (amd64)
                │  (DMZ)        │  Reverse proxy + IDS
                │               │
                │  Traefik ───── TLS, HSTS, rate limiting
                │  CrowdSec ──── IDS/IPS (bouncer nftables)
                │  Ntfy ──────── Notifications (Bearer auth)
                │  nftables ──── policy drop, 4 ports
                └───────┬────────┘
                        │
                Tunnel WireGuard E2E (NetBird mesh)
                        │
                ┌───────┴────────┐
                │  CERVEAU       │  Raspberry Pi 5 (arm64)
                │  (LAN)        │  Zero port internet
                │               │
                │  Seafile       Cloud personnel
                │  Vaultwarden   Mots de passe
                │  Immich        Photos (cold storage)
                │  AdGuard Home  DNS + ad blocking
                │  BentoPDF      Conversion PDF
                │  Portfolio     Site personnel
                └────────────────┘
```

## Stack

| Composant | Role |
|-----------|------|
| **Traefik** | Reverse proxy, TLS Let's Encrypt, middlewares securite |
| **NetBird** | Mesh VPN WireGuard (server sur VPS, clients partout) |
| **CrowdSec** | IDS communautaire + bouncer nftables sur l'hote |
| **Ntfy** | Notifications push (public, deny-all + Bearer token) |
| **ZFS** | Snapshots NVMe miroir sur Pi |
| **GPG** | Backup chiffre off-site vers VPS |
| **LUKS** | Backup air-gapped sur SSD USB |

## Deploiement

### Prerequis

- Ansible >= 2.15
- Python 3.12+
- Cle SSH Ed25519
- Fichiers vault remplis et chiffres (voir `*.example`)

### Commandes

```bash
# Phase 1 — Infrastructure (socle + mesh)
ansible-playbook -i inventory.ini playbooks/infrastructure.yml --ask-vault-pass

# ⚠️  Enrollment NetBird manuel entre les 2 phases

# Phase 2 — Services (apps + backup + monitoring)
ansible-playbook -i inventory.ini playbooks/services.yml --ask-vault-pass

# Phase 2b — Configuration mesh (ACLs + DNS)
ansible-playbook -i inventory.ini playbooks/mesh-config.yml --ask-vault-pass

# Tout d'un coup (apres enrollment)
ansible-playbook -i inventory.ini playbooks/site.yml --ask-vault-pass

# Cibler une machine
ansible-playbook -i inventory.ini playbooks/services.yml --limit lan --ask-vault-pass

# Cibler un composant
ansible-playbook -i inventory.ini playbooks/services.yml --tags vaultwarden --ask-vault-pass

# Dry run
ansible-playbook -i inventory.ini playbooks/site.yml --check --diff --ask-vault-pass

# Restauration
ansible-playbook -i inventory.ini playbooks/restore.yml --tags vaultwarden --limit lan --ask-vault-pass
```

## Roles (12)

| Role | Contenu |
|------|---------|
| `common` | Packages de base, apt upgrade, unattended-upgrades |
| `base-vps` | nftables, SSH hardening (VPS) |
| `base-pi` | UFW, SSH hardening (Pi) |
| `docker` | Docker Engine + log rotation |
| `backbone` | Traefik + NetBird server (VPS) |
| `netbird-client` | Client NetBird + resolution IP mesh |
| `mesh-config` | ACLs NetBird, DNS mesh, rewrites AdGuard |
| `services-vps` | CrowdSec, Ntfy, bientot-agent, node-exporter |
| `services-pi` | Seafile, Vaultwarden, Immich, AdGuard, BentoPDF, Portfolio, Bientot, veille-secu |
| `backup` | ZFS snapshots, backup GPG vers VPS, backup USB LUKS |
| `monitoring` | Scan CVE Grype, maintenance images Docker |
| `connection-resolver` | Resolution dynamique SSH (local/mesh/CI) |

## Securite

- **Firewall** : nftables policy drop (VPS), UFW deny (Pi)
- **IDS** : CrowdSec + bouncer nftables + whitelist admin
- **Reverse proxy** : HSTS, XSS protection, rate limiting, IP whitelist NetBird
- **Containers** : `no-new-privileges`, `cap_drop: ALL`, healthchecks
- **Secrets** : fichiers `.env` mode 0600, jamais en dur dans les compose
- **SSH** : Ed25519, port custom, password off, root off
- **Mesh** : ACL deny-by-default, 5 policies unidirectionnelles
- **Backup 3-2-1** : ZFS local + GPG off-site + LUKS air-gapped
- **Supply chain** : images GHCR pre-buildees, Grype scan hebdomadaire (Trivy retire mars 2026)

## Documentation

La documentation detaillee est dans [`docs/`](docs/) :

| Fichier | Contenu |
|---------|---------|
| `00-OVERVIEW.md` | Schema reseau, flux, phases |
| `01-MACHINES.md` | Machines, ports, reseaux Docker, ACLs |
| `02-ROLES.md` | 12 roles, tags, dependances |
| `03-WORKFLOW.md` | Run 0, playbooks, mises a jour |
| `04-SECURITY.md` | Securite : firewall, middlewares, containers, backup |
| `07-EXTERNAL-APPS.md` | GitHub Actions, GHCR, publication |
| `08-DISASTER-RECOVERY.md` | 6 scenarios de panne |
| `09-SECRETS.md` | Inventaire secrets, rotation |
| `10-ADDING-MACHINE.md` | Ajout machine au mesh |

## CI/CD

- **CI** : Ansible-lint + syntax check sur push/PR (`main`)
- **CD** : Deploy manuel via `workflow_dispatch` — GitHub Runner → SSH VPS (bastion) → ansible-playbook

## License

Projet personnel. Code source prive.
