# 07 — Plan de développement

## Setup Git

```bash
cd zero-trust
git checkout -b v2

# Toute la nouvelle archi se développe sur v2.
# main = prod actuelle (v1), on y touche pas.
#
# Une fois Portfolio UP en prod avec la v2 :
#   → GitHub Settings → Default branch → v2
#   → Renommer main en v1 (archive)
#   → Renommer v2 en main
#
# Pas de merge : c'est une réécriture complète.
```

---

## Priorité : Portfolio UP le plus vite possible

```
Sprint 0 → socle (base + docker + netbird)      = l'infra fonctionne
Sprint 1 → traefik edge + portfolio              = le site est UP
           
Tout le reste vient après.
```

---

## Sprint 0 — Socle

### 0.1 — DEV : rôle `base`

```
Fichiers à créer :
  roles/base/defaults/main.yml       → variables par défaut
  roles/base/tasks/main.yml          → point d'entrée
  roles/base/tasks/packages.yml      → apt install
  roles/base/tasks/users.yml         → user admin + user deploy
  roles/base/tasks/ssh.yml           → hardening SSH
  roles/base/tasks/nftables.yml      → firewall policy drop in+out
  roles/base/templates/nftables.conf.j2
  roles/base/templates/sshd_config.j2
  roles/base/handlers/main.yml       → reload nftables, restart sshd

Variables à définir (defaults/main.yml) :
  base_ssh_port: 2222
  base_admin_user: "lucas"
  base_deploy_user: "deploy"
  base_packages:
    - curl
    - wget
    - jq
    - unattended-upgrades
    - nftables
  base_nftables_output_allow: []     → surchargé dans host_vars

Ce que le rôle fait :
  1. Installe les paquets de base
  2. Crée le user admin (sudo, clé SSH)
  3. Crée le user deploy (nologin, NOPASSWD, clé SSH dédiée)
  4. Durcit SSH (port custom, clé only, root off, password off)
  5. Configure nftables (policy drop in+out, allowlists)

Ce que le rôle ne fait PAS :
  - Installer Docker (c'est le rôle docker)
  - Configurer NetBird (c'est le rôle netbird)
  - Déployer des services
```

### 0.1 — TEST : rôle `base`

```bash
# Sur le VPS de test (terraform apply)
ansible-playbook playbooks/site.yml --tags infra \
  -i inventory/test.yml --tags base --limit test_vps

# Vérifier que ça MARCHE
ssh admin@IP -p 2222                 # ✅
sudo nft list ruleset                # ✅ policy drop

# Vérifier que ça BLOQUE
ssh root@IP -p 22                    # ❌ refusé
curl http://google.com               # ❌ output drop

# Idempotence : relancer → 0 changed
# Commit sur la branche v3
```

---

### 0.2 — DEV : rôle `docker`

```
Fichiers à créer :
  roles/docker/defaults/main.yml
  roles/docker/tasks/main.yml
  roles/docker/tasks/engine.yml        → install Docker CE (multi-arch)
  roles/docker/tasks/daemon.yml        → daemon.json
  roles/docker/tasks/socket_proxy.yml  → container socket proxy
  roles/docker/templates/daemon.json.j2
  roles/docker/templates/docker-compose.socket-proxy.yml.j2
  roles/docker/handlers/main.yml       → restart docker

Variables :
  docker_socket_proxy_image: "tecnativa/docker-socket-proxy"
  docker_socket_proxy_version: "0.1.2"
  docker_socket_proxy_permissions:
    containers: 1
    images: 1
    networks: 1
    info: 1
    events: 1
    exec: 0
    post: 0
    volumes: 0

Ce que le rôle fait :
  1. Installe Docker CE (repo officiel, multi-arch amd64/arm64)
  2. Configure daemon.json (log rotation)
  3. Déploie le socket proxy (container read-only)
  4. Crée le réseau socket-proxy-net (internal: true)

Ce que le rôle ne fait PAS :
  - Déployer des services applicatifs
  - Gérer les composes des services
```

### 0.2 — TEST : rôle `docker`

```bash
ansible-playbook playbooks/site.yml --tags infra \
  -i inventory/test.yml --tags docker --limit test_vps

# Vérifier que ça MARCHE
docker version                       # ✅
docker ps | grep socket-proxy        # ✅

# Vérifier que l'isolation internal:true fonctionne
docker network create --internal test-isolated
docker run --rm --network test-isolated alpine wget -qO- http://google.com
                                     # ❌ bloqué (internal: true)
docker network rm test-isolated

# Vérifier que non-internal PEUT sortir (comportement normal Docker)
docker run --rm alpine wget -qO- http://google.com
                                     # ✅ fonctionne (réseau par défaut, non-internal)
# C'est attendu — l'isolation se fait au niveau du réseau Docker, pas du host

# Idempotence → 0 changed
# Commit
```

---

### 0.3 — DEV : rôle `netbird_server`

```
Fichiers à créer :
  roles/netbird_server/defaults/main.yml
  roles/netbird_server/tasks/main.yml
  roles/netbird_server/templates/docker-compose.yml.j2
  roles/netbird_server/templates/env.j2

Variables :
  netbird_server_version: "0.28.0"
  netbird_server_domain: "netbird.tondomaine.fr"
  netbird_server_stun_port: 3478
  # + secrets dans vault

Ce que le rôle fait :
  1. Déploie NetBird management + signal + coturn via compose
  2. Réseau netbird-net (internal: false — STUN public)
```

### 0.3 — TEST

```bash
ansible-playbook playbooks/site.yml --tags infra \
  -i inventory/test.yml --tags netbird --limit test_vps

docker ps | grep netbird             # ✅
# Dashboard accessible
# Commit
```

---

### 0.4 — DEV : rôle `netbird_client`

```
Fichiers à créer :
  roles/netbird_client/defaults/main.yml
  roles/netbird_client/tasks/main.yml
  roles/netbird_client/tasks/enroll.yml

Variables :
  netbird_client_setup_key: ""       → passé en -e ou dans vault
  netbird_server_url: "https://netbird.tondomaine.fr"

Ce que le rôle fait :
  1. Installe le client NetBird
  2. Enroll le nœud avec la setup key
  3. Stocke l'IP mesh comme fact Ansible
```

### 0.4 — TEST

```bash
# Sur un 2ème VPS de test ou directement sur le Pi
ansible-playbook playbooks/site.yml --tags infra \
  -i inventory/test.yml --tags netbird --limit test_pi \
  -e netbird_client_setup_key="XXXXX"

netbird status                       # ✅ connected
ping 100.64.x.x                     # ✅ mesh OK
# Commit
```

---

### 0.5 — PROD : appliquer le socle

```bash
# VPS prod
ansible-playbook playbooks/site.yml --tags infra \
  -i inventory/prod.yml --limit vps --check --diff
ansible-playbook playbooks/site.yml --tags infra \
  -i inventory/prod.yml --limit vps

# Pi prod
ansible-playbook playbooks/site.yml --tags infra \
  -i inventory/prod.yml --limit pi --check --diff
ansible-playbook playbooks/site.yml --tags infra \
  -i inventory/prod.yml --limit pi

# Vérifier le mesh
ping 100.64.x.x                     # ✅ VPS ↔ Pi OK
```

---

## Sprint 1 — Portfolio UP 🎯

### 1.1 — DEV : rôle `traefik`

```
Fichiers à créer :
  roles/traefik/defaults/main.yml
  roles/traefik/tasks/main.yml
  roles/traefik/templates/docker-compose.yml.j2
  roles/traefik/templates/traefik.yml.j2         → config statique
  roles/traefik/templates/env.j2
  roles/traefik/handlers/main.yml

Variables (defaults) :
  traefik_mode: "edge"                → "edge" ou "internal"
  traefik_version: "3.6"
  traefik_listen_address: "0.0.0.0"   → surchargé pour internal
  traefik_tls_email: ""               → email ACME Let's Encrypt
  traefik_enable_waf: true            → false sur internal
  traefik_enable_crowdsec: true       → false sur internal
  traefik_network_name: "traefik-{{ traefik_mode }}-net"
  # Mode TLS auto-détecté (set_fact traefik_tls_mode au début du play) :
  #   vault_cloudflare_dns_api_token rempli → DNS-01 wildcard
  #   sinon                                 → HTTP-01 fallback

Ce que le rôle fait :
  1. Crée le réseau traefik-<mode>-net
  2. Génère la config statique Traefik (entrypoints, certificats)
  3. Déploie le compose (container traefik-<mode>)
  4. Rejoint socket-proxy-net (Docker provider)

Le template s'adapte au mode via des conditions Jinja2.
Un seul rôle, deux comportements. Voir 06-ANSIBLE pour les détails.
```

### 1.1 — TEST

```bash
ansible-playbook playbooks/site.yml \
  -i inventory/test.yml --tags services --limit test_vps

docker ps | grep traefik-edge        # ✅
curl -k https://localhost             # ✅ Traefik répond (404)
# Commit
```

---

### 1.2 — DEV : rôle `portfolio`

```
Fichiers à créer :
  roles/portfolio/defaults/main.yml
  roles/portfolio/tasks/main.yml
  roles/portfolio/templates/docker-compose.yml.j2

Variables :
  portfolio_version: "1.3.0"
  portfolio_image: "ghcr.io/ldesfontaine/termfolio"
  portfolio_domain: "portfolio.tondomaine.fr"
  portfolio_network_name: "portfolio-net"

Ce que le rôle fait :
  1. Crée /opt/modules/portfolio/
  2. Génère le docker-compose (réseau portfolio-net, internal: true)
  3. Labels Traefik pour le routing automatique
  4. Container read_only: true
  5. docker compose up

Compose attendu (simplifié) :
  services:
    portfolio:
      image: {{ portfolio_image }}:{{ portfolio_version }}
      read_only: true
      security_opt: [no-new-privileges:true]
      cap_drop: [ALL]
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.portfolio.rule=Host(`{{ portfolio_domain }}`)"
        - "traefik.http.routers.portfolio.tls.certresolver=letsencrypt"
        - "traefik.docker.network=portfolio-net"
      networks:
        - portfolio-net

  networks:
    portfolio-net:
      internal: true
      # Traefik sera connecté automatiquement par le rôle Traefik
      # Pas de réseau external: true — chaque service est isolé
```

### 1.2 — TEST

```bash
ansible-playbook playbooks/site.yml \
  -i inventory/test.yml --tags services --limit test_vps

docker ps | grep portfolio           # ✅
curl -k https://localhost             # ✅ Portfolio affiché

# Sécurité
docker exec portfolio wget http://google.com  # ❌ bloqué

# Idempotence → 0 changed
# Commit
```

---

### 1.3 — PROD : Portfolio UP

```bash
ansible-playbook playbooks/site.yml \
  -i inventory/prod.yml --limit vps --check --diff
ansible-playbook playbooks/site.yml \
  -i inventory/prod.yml --limit vps

curl https://portfolio.tondomaine.fr  # ✅ 🎉 UP
# Commit + v2 devient la branche principale
```

---

## Sprint 2 → N — le cycle

```
Pour chaque nouveau service :

1. DEV — créer le rôle (defaults, tasks, templates)
   Fichiers listés, variables nommées, compose décrit

2. TEST — lancer sur VPS de test
   Vérifier que ça marche + que ça bloque ce qu'il faut

3. NON-RÉGRESSION
   curl https://portfolio.tondomaine.fr  → toujours UP ?
   docker ps                             → anciens containers OK ?

4. PROD — --check --diff puis apply

5. COMMIT
```

### Ordre

```
Sprint 2  — ntfy           → notifications (utile dès le sprint 3)
Sprint 3  — crowdsec       → IDS (protège le portfolio)
Sprint 4  — bientot_agent  → monitoring VPS
Sprint 5  — traefik (int.) → reverse proxy Pi (mode internal)
Sprint 6  — adguard        → DNS mesh
Sprint 7  — vaultwarden    → mots de passe
Sprint 8  — seafile        → fichiers (3 containers)
Sprint 9  — bientot_master → dashboard monitoring
Sprint 10 — veille_secu    → CVE
Sprint 11 — immich         → photos (le plus gros)
Sprint 12 — bentopdf       → conversion PDF
Sprint 13 — backup         → ZFS + GPG + USB
```

---

## Pourquoi ça ne casse pas les services existants

```
Chaque service = son propre dossier /opt/modules/<service>/
Ajouter un service = créer un NOUVEAU dossier + compose
Les autres dossiers ne sont JAMAIS touchés

Seul risque : nftables reload (si nouvelle règle output)
  → --check --diff AVANT d'apply
  → reload ≠ restart (connexions maintenues)

Si ça casse : docker compose down /opt/modules/<nouveau>/
Le reste tourne toujours.
```

---

## Checklist non-régression (chaque sprint)

```bash
docker ps                              # tous les containers OK
curl https://portfolio.tondomaine.fr   # portfolio UP
docker exec <nouveau> ping <ancien>    # ❌ réseaux séparés
docker exec <nouveau> wget http://google.com  # ❌ internal:true
ansible-playbook ... (2ème run)        # 0 changed
```


## Documentation
```
On ecrit un readme global, puis un readme dans chaque role qui explique leur actions & objectifs. On explique leur modularité