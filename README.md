# Homelab Zero Trust — Déploiement Ansible

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
└── NetBird Server         → orchestrateur mesh VPN WireGuard

        ║ Tunnel WireGuard chiffré (E2E)
        ▼

Raspberry Pi 5 — Cerveau (LAN local, zéro port ouvert)
├── Nextcloud              → cloud personnel
├── Vaultwarden            → gestionnaire de mots de passe
├── Grafana                → dashboards monitoring
├── VictoriaMetrics        → base de métriques
├── vmagent                → collecteur (scrape Pi + VPS via NetBird)
├── AdGuard Home           → DNS resolver mesh + blocage pub
├── BentoPDF               → outil PDF (public via VPS)
└── Portfolio (termfolio)  → site vitrine (public via VPS)
```

### Réseaux Docker sur le Pi

```
brain_public   → BentoPDF, Portfolio  (accessibles publiquement via VPS proxy)
brain_private  → Nextcloud, Vaultwarden, Grafana, AdGuard (VPN NetBird requis)
```

### ACLs NetBird (Zero Trust)

```
admins      ↔ sentinelle  : accès total (SSH, management)
admins      ↔ cerveau     : accès total (SSH, services)
sentinelle  → cerveau     : TCP 8090-8093, 3000, 3001 uniquement (backends Traefik)
cerveau     → sentinelle  : TCP 9100 uniquement (monitoring node-exporter)
sentinelle  ↔ cerveau     : ICMP (health checks)
```

---

## Structure du projet

```
deployVps/
├── inventory.ini                  # Hôtes cibles
├── setup.yml                      # Playbook principal (4 plays, 8 phases)
├── ansible.cfg                    # SSH keepalives, pipelining
│
├── group_vars/
│   └── all.yml                    # Versions images, domaine, sous-domaines, IPs NetBird
│
├── host_vars/
│   ├── vps_serv.yml               # Secrets VPS  ← chiffrer avec ansible-vault
│   └── pi_serv.yml                # Secrets Pi   ← chiffrer avec ansible-vault
│
├── tasks/
│   ├── system_vps.yml             # apt upgrade, UFW, unattended-upgrades
│   ├── system_pi.yml              # apt upgrade, UFW, désactivation avahi
│   ├── hardening.yml              # SSH durci VPS (Ed25519, port 2222)
│   ├── hardening_pi.yml           # SSH durci Pi  (Ed25519, port 2223)
│   ├── docker.yml                 # Docker Engine (amd64 + arm64)
│   ├── stack_vps.yml              # Stack VPS (Traefik, CrowdSec, NetBird, node-exporter)
│   ├── stack_pi.yml               # Stack Pi (assert ZFS, docker-compose, AdGuard init)
│   ├── netbird_client.yml         # Installation client NetBird
│   ├── netbird_dns.yml            # Configure AdGuard comme DNS resolver NetBird
│   ├── netbird_acl.yml            # Crée groupes + policies ACL Zero Trust
│   ├── adguard_dns.yml            # DNS rewrites AdGuard → services Pi privés
│   └── crowdsec_bouncer.yml       # Bouncer nftables VPS
│
├── templates/
│   ├── sshd_config.j2                    # SSH durci (algos modernes)
│   ├── docker-compose_vps_yml.j2         # Stack VPS
│   ├── docker-compose_pi_yml.j2          # Stack Pi
│   ├── traefik_dynamic_yml.j2            # Routers Traefik + middleware ipWhiteList
│   ├── vmagent_config_yml.j2             # Scrape Pi + VPS via NetBird
│   ├── adguardhome_yaml.j2               # Config initiale AdGuard (skip wizard)
│   ├── netbird_config_yaml.j2            # Config client NetBird
│   ├── acquis_yaml.j2                    # Sources CrowdSec
│   └── crowdsec-firewall-bouncer_yaml.j2 # Bouncer nftables
│
└── handlers/
    └── main.yml                   # Reload Docker stacks
```

---

## Prérequis

```bash
# Ansible >= 2.14
pip install ansible

# Collections requises
ansible-galaxy collection install ansible.posix

# Clé SSH Ed25519 dédiée (recommandé)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_vps_homelab
# → renseigner ssh_key_path et priv_ssh_key_path dans group_vars/all.yml
```

---

## Étape 1 — Configurer les variables

### `group_vars/all.yml`

Ce fichier contient la configuration partagée (pas de secrets) :

```yaml
# Versions des images Docker (à mettre à jour selon besoins)
traefik_version: "v2.11"
nextcloud_version: "30"
# ... autres versions

# Domaine de base
vault_base_domain: "ton-domaine.com"
vault_admin_email: "ton@email.com"

# Sous-domaines (DNS A → IP publique VPS requis pour Let's Encrypt)
netbird_subdomain: "mesh"
bentopdf_subdomain: "pdf"
portfolio_subdomain: "portfolio"
nextcloud_subdomain: "cloud"
vaultwarden_subdomain: "vault"
grafana_subdomain: "grafana"
adguard_subdomain: "adguard"

# SSH
ssh_key_path: "~/.ssh/id_ed25519_vps_homelab.pub"
priv_ssh_key_path: "~/.ssh/id_ed25519_vps_homelab"

# IPs NetBird — renseigner après enrollment (Run 1 → Run 2)
vault_vps_netbird_ip: "REMPLACER_APRES_ENROLEMENT_NETBIRD"
vault_pi_netbird_ip:  "REMPLACER_APRES_ENROLEMENT_NETBIRD"

# IP publique VPS
vault_vps_mgmt_ip: "XX.XX.XX.XX"

# User SSH final (commun aux deux machines)
vault_pi_ssh_user: "lucas"
```

### `host_vars/vps_serv.yml`

```yaml
# Bootstrap (connexion initiale root:22 — Run 1 uniquement)
vault_ssh_password: "MOT_DE_PASSE_ROOT_OVH"

# Connexion finale
vault_ssh_user: "lucas"
vault_ssh_port: 2222

# Chemins
stack_dir: "/opt/stack"

# Secrets services VPS
vault_netbird_turn_password: ""      # openssl rand -hex 32
vault_crowdsec_lapi_key: ""          # openssl rand -hex 16
vault_netbird_api_token: ""          # Générer dans dashboard NetBird → Personal Access Tokens
```

### `host_vars/pi_serv.yml`

```yaml
# Bootstrap (connexion initiale admin:22 — Run 1 uniquement)
vault_pi_bootstrap_user: "admin"
vault_pi_bootstrap_password: "MOT_DE_PASSE_PI"

# Connexion finale
vault_pi_ip: "192.168.1.XX"
vault_pi_ssh_port: 2223

# Chemins
pi_stack_dir: "/mnt/tank/stack"       # Doit être un montage ZFS actif

# Nextcloud
vault_nextcloud_admin_user: "admin"
vault_nextcloud_admin_password: ""    # mot de passe complexe
vault_nextcloud_db_password: ""       # openssl rand -hex 16

# Vaultwarden
vault_vaultwarden_admin_token: ""     # openssl rand -base64 48

# AdGuard Home
vault_adguard_admin_user: "admin"
vault_adguard_admin_password: ""      # mot de passe complexe
# Hash bcrypt du mot de passe AdGuard :
# python3 -c "import bcrypt; print(bcrypt.hashpw(b'TON_MOT_DE_PASSE', bcrypt.gensalt(10)).decode())"
vault_adguard_admin_password_hash: "" # $2b$10$...

# Grafana
vault_grafana_admin_password: ""      # mot de passe complexe

# NetBird API (même token que dans vps_serv.yml)
vault_netbird_api_token: ""
```

### Générer les secrets

```bash
# Mots de passe DB et clés API
openssl rand -hex 16

# Token Vaultwarden
openssl rand -base64 48

# Hash bcrypt pour AdGuard (nécessite le package bcrypt)
pip install bcrypt
python3 -c "import bcrypt; print(bcrypt.hashpw(b'TON_MOT_DE_PASSE', bcrypt.gensalt(10)).decode())"
```

### Chiffrer les secrets avec Ansible Vault

```bash
ansible-vault encrypt host_vars/vps_serv.yml
ansible-vault encrypt host_vars/pi_serv.yml
# → saisir un mot de passe maître (conserver précieusement)
```

### Mettre à jour l'inventaire

```ini
# inventory.ini
[vps]
vps_serv ansible_host=XX.XX.XX.XX ...

[pi]
pi_serv ansible_host=192.168.1.XX ...  # ← IP locale du Pi
```

### DNS A records à créer chez ton registrar

Tous ces sous-domaines doivent pointer vers l'IP publique du VPS pour que Traefik puisse émettre les certificats Let's Encrypt :

```
mesh.ton-domaine.com      → IP_VPS
pdf.ton-domaine.com       → IP_VPS
portfolio.ton-domaine.com → IP_VPS
cloud.ton-domaine.com     → IP_VPS
vault.ton-domaine.com     → IP_VPS
grafana.ton-domaine.com   → IP_VPS
adguard.ton-domaine.com   → IP_VPS
```

---

## Étape 2 — Run 1 : provisioning initial

```bash
ansible-playbook -i inventory.ini setup.yml --ask-vault-pass
```

Ce qui se passe :

| Play | Connexion | Actions |
|------|-----------|---------|
| Play 1 — Bootstrap VPS | `root:22` (mot de passe OVH) | Crée l'utilisateur `lucas`, injecte la clé SSH |
| Play 2 — Sentinelle VPS | `lucas:2222` (clé SSH) | Système, SSH durci, Docker, stack VPS (Traefik, CrowdSec, NetBird), bouncer |
| Play 3 — Bootstrap Pi | `admin:22` (mot de passe Pi) | Crée l'utilisateur `lucas`, injecte la clé SSH |
| Play 4 — Cerveau Pi | `lucas:2223` (clé SSH) | Système, SSH durci, Docker, NetBird client, stack Pi |

A la fin du Run 1 :
- Tous les services sont up
- Les ports des services Pi sont bindés sur `127.0.0.1` (en attente des IPs NetBird)
- NetBird est installé mais les machines ne sont pas encore enrôlées dans le mesh

---

## Étape 3 — Enrollment NetBird (entre Run 1 et Run 2)

> Cette étape est manuelle. Elle ne peut pas être automatisée car NetBird génère les clés WireGuard localement sur chaque machine.

### 3.1 — Créer un Setup Key dans le dashboard NetBird

Accède à `https://mesh.ton-domaine.com` et crée un **Setup Key** de type `Reusable` (ou deux clés `One-time`).

### 3.2 — Enrôler le VPS

```bash
ssh lucas@IP_VPS -p 2222

sudo netbird up \
  --setup-key TON_SETUP_KEY \
  --management-url http://IP_VPS:33073

# Vérifier l'enrollment
netbird status
# Exemple de sortie :
# Peers count: 1/1 Connected
# NetBird IP: 100.121.243.246/16
```

**Noter l'IP WireGuard du VPS** (ex: `100.121.243.246`)

### 3.3 — Enrôler le Pi

```bash
ssh lucas@192.168.1.XX -p 2223

sudo netbird up \
  --setup-key TON_SETUP_KEY \
  --management-url http://IP_VPS:33073

netbird status
# NetBird IP: 100.121.191.170/16
```

**Noter l'IP WireGuard du Pi** (ex: `100.121.191.170`)

### 3.4 — Mettre à jour `group_vars/all.yml`

```bash
# Éditer directement (pas de vault sur ce fichier)
nano group_vars/all.yml

# Renseigner les deux IPs WireGuard notées ci-dessus :
vault_vps_netbird_ip: "100.121.243.246"
vault_pi_netbird_ip:  "100.121.191.170"
```

### 3.5 — Enrôler son laptop/phone (facultatif mais recommandé avant Run 2)

Installer le client NetBird sur ses appareils admin et les connecter au mesh **avant** de lancer le Run 2. Cela permet à la Phase 8 (ACL) de détecter les peers admin et de créer le groupe `admins` correctement.

```bash
# Linux/macOS
curl -fsSL https://pkgs.netbird.io/install.sh | sh
netbird up --setup-key TON_SETUP_KEY --management-url http://IP_VPS:33073
```

---

## Étape 4 — Run 2 : configuration complète

```bash
ansible-playbook -i inventory.ini setup.yml --ask-vault-pass
```

Ce qui se passe en plus du Run 1 :

| Phase | Actions |
|-------|---------|
| Phase 5 — Stack Pi | Regénère les docker-compose avec les vraies IPs NetBird (ports bindés sur l'IP WireGuard) |
| Phase 6 — DNS NetBird | Configure AdGuard comme DNS resolver pour tous les peers du mesh |
| Phase 7 — DNS Rewrites | Crée les rewrites AdGuard : `cloud/vault/grafana/adguard.ton-domaine.com` → IP NetBird VPS |
| Phase 8 — ACL NetBird | Crée groupes `sentinelle`/`cerveau`/`admins` + 5 policies Zero Trust, supprime la policy `Default` |

A la fin du Run 2 :
- Tous les services sont accessibles via leurs sous-domaines HTTPS
- Les services privés (cloud, vault, grafana, adguard) nécessitent un client NetBird actif
- La policy Default (All→All) est supprimée — deny-by-default actif

---

## Accès aux services après Run 2

### Services publics (sans VPN)

| URL | Service |
|-----|---------|
| `https://pdf.ton-domaine.com` | BentoPDF |
| `https://portfolio.ton-domaine.com` | Portfolio |

### Services privés (client NetBird requis)

| URL | Service |
|-----|---------|
| `https://cloud.ton-domaine.com` | Nextcloud |
| `https://vault.ton-domaine.com` | Vaultwarden |
| `https://grafana.ton-domaine.com` | Grafana |
| `https://adguard.ton-domaine.com` | AdGuard Home |

### Dashboard NetBird

| URL | Service |
|-----|---------|
| `https://mesh.ton-domaine.com` | Dashboard NetBird (gestion peers, ACLs) |

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
| 8092 | IP NetBird | Nextcloud |
| 8093 | IP NetBird | Vaultwarden |
| 3000 | IP NetBird | AdGuard Home UI |
| 3001 | IP NetBird | Grafana |
| 5353 | IP NetBird | AdGuard DNS (UDP/TCP) |
| 9100 | IP NetBird | Node Exporter |
| 8428 | 127.0.0.1 | VictoriaMetrics (local uniquement) |

---

## Commandes utiles

### Relancer uniquement le Pi ou le VPS

```bash
ansible-playbook -i inventory.ini setup.yml --ask-vault-pass --limit pi
ansible-playbook -i inventory.ini setup.yml --ask-vault-pass --limit vps
```

### Vérifier la connectivité

```bash
# Pi (après Run 1)
ssh lucas@192.168.1.XX -p 2223 -i ~/.ssh/id_ed25519_vps_homelab

# VPS (après Run 1)
ssh lucas@IP_VPS -p 2222 -i ~/.ssh/id_ed25519_vps_homelab
```

### Gérer les secrets Vault

```bash
# Voir le contenu d'un fichier chiffré
ansible-vault view host_vars/pi_serv.yml

# Modifier un fichier chiffré
ansible-vault edit host_vars/vps_serv.yml

# Rechiffrer après modification manuelle
ansible-vault encrypt host_vars/pi_serv.yml
```

### Vérifier les containers sur le Pi

```bash
ssh lucas@192.168.1.XX -p 2223
docker ps
docker logs nextcloud --tail 30
```

### Vérifier les ACLs NetBird

```bash
# Lister les groupes
curl -s -H 'Authorization: Token TON_TOKEN' \
  https://mesh.ton-domaine.com/api/groups | python3 -m json.tool

# Lister les policies
curl -s -H 'Authorization: Token TON_TOKEN' \
  https://mesh.ton-domaine.com/api/policies | python3 -m json.tool
```

---

## Est-ce que relancer Ansible wipe les données ?

**Non.** Ansible est idempotent. Les données sont préservées :

- Les volumes Docker (`/mnt/tank/stack/`) ne sont jamais supprimés par Ansible
- `docker compose up -d` redémarre uniquement les containers dont la config a changé
- Les clés NetBird (`/etc/netbird/`) ne sont pas touchées
- La config AdGuard (`/mnt/tank/stack/adguard/conf/AdGuardHome.yaml`) n'est déployée qu'une seule fois (condition `when: not adguard_conf_file.stat.exists`)

**Cas particulier — MariaDB (Nextcloud) :**
Le répertoire `/mnt/tank/stack/nextcloud/db/` n'est pas dans la boucle de création Ansible (Ansible ne force pas `owner: lucas` dessus). MariaDB (UID 999 dans le container) gère ses propres permissions. Ne pas faire `chown lucas` sur ce répertoire manuellement.

## Sécurité

- Tous les secrets sont dans `host_vars/` chiffrés avec `ansible-vault`
- `group_vars/all.yml` ne contient aucun secret (versions, domaine, config partagée)
- Les IPs NetBird dans `group_vars/all.yml` ne sont pas des secrets

**Ne jamais committer :**
```gitignore
# Ajouter dans .gitignore
host_vars/vps_serv.yml.bak
host_vars/pi_serv.yml.bak
*.retry
.vault_pass
```

**Avertissement :** si `host_vars/*.yml` sont chiffrés avec ansible-vault, ils peuvent être commités en toute sécurité. Si déchiffrés (vault decrypt), ne pas commiter.
