# 06 — Ansible : conventions et structure

## Conventions de code

### Langue

```yaml
# Noms de rôles, variables, fichiers    → anglais
# Noms de tasks (name:)                 → français
# Commentaires                          → français
# Noms de templates (.j2)               → anglais
```

### Style

```yaml
# FQCN obligatoire
ansible.builtin.apt:          # ✅ oui
apt:                          # ❌ non

# Une task = une action
# Chaque task a un name: qui dit CE QU'ELLE FAIT en français
# Les commentaires expliquent POURQUOI, pas quoi
# Pas de one-liner, pas de Jinja2 complexe inline

# ✅ Lisible
- name: "Firewall — Ouvrir le port SSH durci"
  ansible.builtin.lineinfile:
    path: /etc/nftables.conf
    line: "tcp dport {{ ssh_port }} accept"

# ❌ Illisible
- lineinfile: path=/etc/nftables.conf line="tcp dport {{ssh_port}} accept"
```

### Variables

```yaml
# Préfixées par le nom du rôle — jamais génériques
traefik_mode: "edge"                  # ✅
mode: "edge"                          # ❌ ambigu

crowdsec_bouncer_api_key: "xxx"       # ✅
api_key: "xxx"                        # ❌ de quel service ?

seafile_db_password: "xxx"            # ✅
db_password: "xxx"                    # ❌ quelle DB ?

# Secrets dans vault, préfixés vault_
vault_seafile_db_password: "..."

# Pas de variable calculée complexe inline
# ✅ Clair
netbird_ip: "100.64.1.10"

# ❌ Incompréhensible
listen_addr: "{{ hostvars[inventory_hostname]['ansible_wt0']['ipv4']['address'] | default('0.0.0.0') }}"
```

### Fichiers et structure d'un rôle

```yaml
# Un rôle ne modifie JAMAIS les fichiers d'un autre rôle
# Chaque rôle est testable seul
# Les handlers sont DANS le rôle, jamais partagés entre rôles
# Si deux rôles ont besoin du même handler → chacun a le sien
```

---

## Arborescence du repo

```
zero-trust/
├── inventory/
│   └── hosts.yml               # machines + machine_services
│
├── host_vars/
│   ├── vps.yml                  # variables spécifiques VPS (non chiffré)
│   ├── vps_vault.yml            # secrets VPS (ansible-vault chiffré)
│   ├── pi.yml                   # variables spécifiques Pi
│   └── pi_vault.yml             # secrets Pi (ansible-vault chiffré)
│
├── group_vars/
│   └── all.yml                  # variables communes à toutes les machines
│
├── versions.yml                 # versions pinnées (éditable GitHub mobile)
│
├── playbooks/
│   ├── site.yml                 # déploiement complet (infra + services)
│   └── update_service.yml       # mise à jour version d'un service
│
├── roles/
│   ├── base/                    # OS, nftables, SSH, packages
│   ├── docker/                  # Docker engine, daemon.json, socket proxy
│   ├── netbird_server/          # NetBird management + STUN
│   ├── netbird_client/          # NetBird client enrollment
│   ├── traefik/                 # Reverse proxy (mode: edge | internal)
│   ├── crowdsec/                # Engine (container) + bouncer (host)
│   ├── ntfy/                    # Notifications push
│   ├── bentopdf/                # Conversion PDF
│   ├── portfolio/               # Site perso
│   ├── seafile/                 # Cloud fichiers
│   ├── vaultwarden/             # Mots de passe
│   ├── immich/                  # Photos/vidéos
│   ├── adguard/                 # DNS mesh
│   ├── veille_secu/             # Collecteur CVE
│   ├── bientot_master/          # Dashboard monitoring
│   ├── bientot_agent/           # Agent monitoring
│   └── backup/                  # ZFS + GPG + USB
│
├── .github/workflows/
│   ├── ci.yml                   # lint + syntax-check
│   ├── deploy_service.yml       # workflow 2 — version bump
│   └── deploy_infra.yml         # workflow 3 — changement infra (utilise site.yml --tags infra)
│
└── .ansible-lint                # config linter
```

---

## Comment un rôle fonctionne — anatomie

```
roles/seafile/
├── tasks/
│   └── main.yml                 # point d'entrée, lisible de haut en bas
├── templates/
│   ├── docker-compose.yml.j2    # compose autonome
│   └── env.j2                   # .env avec secrets
├── handlers/
│   └── main.yml                 # restart si config change
├── defaults/
│   └── main.yml                 # valeurs par défaut des variables
└── meta/
    └── main.yml                 # dépendances (optionnel)
```

### Exemple : roles/seafile/defaults/main.yml

```yaml
# Valeurs par défaut du rôle Seafile
# Peuvent être surchargées dans host_vars/<machine>.yml

seafile_version: "11.0.13"
seafile_port: 8082
seafile_data_dir: "/opt/modules/seafile/data"
seafile_network_name: "seafile-net"

# Les secrets ne sont PAS ici — ils sont dans host_vars/<machine>_vault.yml
# et référencés via vault_seafile_db_password, vault_seafile_admin_token, etc.
```

### Exemple : roles/seafile/tasks/main.yml

```yaml
# ============================================================
# Seafile — cloud de fichiers personnel
#
# Déploie un compose autonome avec :
#   - Seafile (app)
#   - MariaDB (DB dédiée, seafile-net uniquement)
#   - Memcached (cache, seafile-net uniquement)
#
# Le compose crée son propre réseau Docker (internal: true).
# Traefik Internal rejoint ce réseau via label.
# La DB n'est JAMAIS exposée hors de seafile-net.
# ============================================================

- name: "Seafile — Créer le répertoire du module"
  ansible.builtin.file:
    path: "{{ seafile_data_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: "Seafile — Générer le fichier .env (secrets)"
  ansible.builtin.template:
    src: env.j2
    dest: "{{ seafile_data_dir }}/.env"
    owner: root
    group: root
    mode: "0600"
  # Le .env est mode 0600 : seul root peut le lire.
  # Le user deploy ne peut PAS voir les secrets.
  notify: Redémarrer Seafile

- name: "Seafile — Déployer le docker-compose"
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: "{{ seafile_data_dir }}/docker-compose.yml"
    owner: root
    group: root
    mode: "0644"
  notify: Redémarrer Seafile

- name: "Seafile — Lancer les containers"
  community.docker.docker_compose_v2:
    project_src: "{{ seafile_data_dir }}"
    state: present
```

---

## Un rôle = un compose autonome

Chaque rôle service génère son propre `docker-compose.yml` dans `/opt/modules/<service>/`. Les composes sont indépendants — `docker compose up` dans un dossier ne touche pas les autres.

```
/opt/modules/
├── seafile/
│   ├── docker-compose.yml     # généré par Ansible
│   ├── .env                   # généré par Ansible, mode 0600
│   └── data/                  # volumes Docker
├── vaultwarden/
│   ├── docker-compose.yml
│   ├── .env
│   └── data/
├── traefik/
│   ├── docker-compose.yml
│   ├── .env
│   └── config/
└── ...
```

---

## Traefik — un rôle, deux comportements

Le rôle `traefik` est paramétré par `traefik_mode`. Le template s'adapte :

```yaml
# roles/traefik/defaults/main.yml
traefik_mode: "edge"                    # "edge" (VPS) ou "internal" (Pi)
traefik_version: "3.6"
traefik_listen_address: "0.0.0.0"       # surchargé en host_vars
traefik_tls_email: ""                   # email ACME Let's Encrypt
traefik_enable_waf: true                # WAF Coraza uniquement sur edge
traefik_enable_crowdsec: true           # CrowdSec uniquement sur edge
# Le mode TLS (http-01 / dns-01) est auto-détecté par tasks/main.yml :
#   vault_cloudflare_dns_api_token rempli (>10 chars) → DNS-01 + wildcard
#   sinon                                             → HTTP-01 (fallback)
vault_cloudflare_dns_api_token: ""
```

```yaml
# host_vars/vps.yml — Traefik Edge
traefik_mode: "edge"
traefik_listen_address: "0.0.0.0"
traefik_tls_email: "{{ vault_admin_email }}"
traefik_enable_waf: true
traefik_enable_crowdsec: true

# host_vars/pi.yml — Traefik Internal
traefik_mode: "internal"
traefik_listen_address: "{{ netbird_ip }}"
traefik_tls_email: "{{ vault_admin_email }}"
traefik_enable_waf: false               # pas de WAF (trafic mesh trusté)
traefik_enable_crowdsec: false           # pas de CrowdSec sur le Pi

# host_vars/<machine>/vault.yml — chiffré ansible-vault
# vault_cloudflare_dns_api_token: "xxx..."  # présent → DNS-01 wildcard auto
```

Le template docker-compose utilise des conditions Jinja2 :

```yaml
# roles/traefik/templates/docker-compose.yml.j2
services:
  traefik:
    image: traefik:{{ traefik_version }}
    container_name: traefik-{{ traefik_mode }}
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    ports:
      - "{{ traefik_listen_address }}:443:443"
{% if traefik_mode == "edge" %}
      # Port 80 uniquement sur edge (redirect HTTP → HTTPS + challenge ACME)
      - "{{ traefik_listen_address }}:80:80"
{% endif %}
    volumes:
      - ./config:/etc/traefik:ro
      - traefik-certs:/letsencrypt
{% if traefik_enable_crowdsec %}
      # Logs pour CrowdSec (volume partagé en écriture)
      - traefik-logs:/var/log/traefik
{% endif %}
    networks:
      - socket-proxy-net
{% if traefik_enable_crowdsec %}
      # CrowdSec volume pour les logs (pas de réseau partagé)
{% endif %}

networks:
  socket-proxy-net:
    external: true
```

Le compose de Traefik ne contient QUE `socket-proxy-net`. Il n'a pas de réseau service.
C'est le rôle Traefik qui connecte le container aux réseaux de chaque service APRÈS le deploy :

```yaml
# roles/traefik/tasks/main.yml (extrait)

- name: "Traefik — Lancer le container"
  community.docker.docker_compose_v2:
    project_src: "{{ traefik_data_dir }}"
    state: present

# Liste des services qui ne sont PAS derrière Traefik
# (pas besoin de connecter leur réseau)
# Définie dans inventory/group_vars/all/main.yml (variable globale)
# car utilisée à la fois par le rôle traefik ET par site.yml play 3.
traefik_excluded_services:
  - traefik
  - bientot_agent
  - crowdsec              # CrowdSec lit les logs via volume, pas via réseau

- name: "Traefik — Se connecter au réseau de chaque service"
  ansible.builtin.command:
    cmd: >
      docker network connect
      {{ item | replace('_', '-') }}-net
      traefik-{{ traefik_mode }}
  loop: "{{ machine_services | difference(traefik_excluded_services) }}"
  register: traefik_connect
  changed_when: traefik_connect.rc == 0
  failed_when:
    - traefik_connect.rc != 0
    - "'already exists' not in traefik_connect.stderr"
    - "'No such network' not in traefik_connect.stderr"
  # already exists = déjà connecté → OK (idempotent)
  # No such network = service pas encore déployé → skip
```

Résultat : sur le VPS tu as un container `traefik-edge`, sur le Pi un container `traefik-internal`. Deux instances, un seul code source. Traefik se connecte automatiquement à chaque service existant.

---

## CrowdSec — le split container/host

```yaml
# roles/crowdsec/tasks/main.yml
# ============================================================
# CrowdSec = deux composants avec deux modes de déploiement :
#
# 1. Engine (container Docker)
#    Lit les logs Traefik, détecte les attaques,
#    maintient la liste des IPs à bannir.
#
# 2. Bouncer nftables (installé sur le HOST)
#    Se connecte à l'Engine via localhost:8080,
#    récupère les décisions, applique les bans dans nftables.
#    DOIT être sur le host car il modifie nftables directement.
# ============================================================

- name: "CrowdSec — Déployer l'Engine (container Docker)"
  ansible.builtin.include_tasks: engine.yml
  tags: [crowdsec, crowdsec-engine]

- name: "CrowdSec — Installer le bouncer nftables (host)"
  ansible.builtin.include_tasks: bouncer.yml
  tags: [crowdsec, crowdsec-bouncer]
```

Le bouncer est installé via apt, configuré via template, et géré par systemd. C'est le seul composant de toute l'infra qui est installé sur le host en dehors de Docker (avec nftables et SSH).

---

## Inventaire — assigner les services aux machines

```yaml
# inventory/hosts.yml
all:
  children:

    dmz:
      hosts:
        vps:
          ansible_host: "XX.XX.XX.XX"
          ansible_port: 2222
          ansible_user: deploy

          # Services déployés sur cette machine
          # Traefik en DERNIER → les réseaux existent déjà
          machine_services:
            - crowdsec
            - ntfy
            - bentopdf
            - portfolio
            - bientot_agent
            - traefik

          # NetBird géré séparément (infra, pas service)
          machine_mesh:
            server: true
            client: true

    private:
      hosts:
        pi:
          ansible_host: "100.64.X.X"
          ansible_port: 2222
          ansible_user: deploy
          ansible_ssh_common_args: "-o ProxyJump=deploy@XX.XX.XX.XX:2222"

          machine_services:
            - adguard
            - seafile
            - vaultwarden
            - immich
            - veille_secu
            - bientot_master
            - bientot_agent
            - traefik          # toujours en dernier

          machine_mesh:
            server: false
            client: true
```

### Ajouter une machine demain

```yaml
        mini-pc:
          ansible_host: "100.64.X.Y"
          ansible_port: 2222
          ansible_user: deploy
          ansible_ssh_common_args: "-o ProxyJump=deploy@XX.XX.XX.XX:2222"

          machine_services:
            - jellyfin
            - bientot_agent
            - traefik          # toujours en dernier

          machine_mesh:
            server: false
            client: true
```

Tu ajoutes l'entrée, tu crées `host_vars/mini-pc.yml`, tu lances `ansible-playbook playbooks/site.yml --limit mini-pc`. Ansible applique la base (rôle base + docker), enroll le noeud sur le mesh (machine_mesh.client), puis boucle sur `machine_services` et déploie jellyfin + bientot_agent + traefik (en dernier).

---

## Playbooks

### site.yml — déploiement complet

```yaml
# playbooks/site.yml
# ============================================================
# Déploiement complet d'un nœud : infra + services.
#
# Play 1 : socle (base + docker) avec auto-detection du port SSH
# Play 2 : NetBird (mesh) — conditionné par machine_mesh
# Play 3 : services applicatifs — boucle sur machine_services
#           Traefik DOIT être en dernier dans machine_services
#           pour que tous les réseaux existent déjà au moment
#           où il s'y connecte.
# ============================================================

- name: "Infrastructure — socle commun à toutes les machines"
  hosts: all
  become: true
  gather_facts: false
  tags: [infra]

  pre_tasks:
    - name: "Tester la connexion sur le port actuel"
      ansible.builtin.wait_for_connection:
        timeout: 5
      ignore_errors: true
      register: ssh_test

    - name: "Basculer sur le port durci si nécessaire"
      ansible.builtin.set_fact:
        ansible_port: "{{ base_ssh_port }}"
      when: ssh_test is failed

    - name: "Collecter les facts manuellement"
      ansible.builtin.setup:

  roles:
    - role: base
      tags: [base]

    - role: docker
      tags: [docker]

- name: "Infrastructure — NetBird (mesh)"
  hosts: all
  become: true
  tags: [infra, netbird]

  tasks:
    - name: "NetBird — Déployer le serveur (VPS uniquement)"
      ansible.builtin.include_role:
        name: netbird_server
      when: machine_mesh.server | default(false)

    - name: "NetBird — Configurer les groupes et ACLs"
      ansible.builtin.include_role:
        name: netbird_config
      when: machine_mesh.server | default(false)

    - name: "NetBird — Enroller le noeud"
      ansible.builtin.include_role:
        name: netbird_client
      when: machine_mesh.client | default(false)

- name: "Services — déploiement modulaire"
  hosts: all
  become: true
  tags: [services]

  tasks:
    # Traefik doit être en dernier dans machine_services.
    # Chaque service crée son propre réseau (<service>-net).
    # Le rôle traefik se connecte à ces réseaux après son deploy.
    - name: "Déployer chaque service assigné à cette machine"
      ansible.builtin.include_role:
        name: "{{ service_item }}"
      loop: "{{ machine_services }}"
      loop_var: service_item
```

### update_service.yml — version bump (workflow 2)

```yaml
# playbooks/update_service.yml
# ============================================================
# Mise à jour de la version d'un service existant.
# Ne touche PAS aux .env, au firewall, ni au réseau.
# Utilisé par le workflow GitHub deploy_service.yml.
#
# Usage : ansible-playbook playbooks/update_service.yml \
#           -e target_service=portfolio \
#           -e target_version=1.4.0 \
#           --limit vps
# ============================================================

- name: "Mise à jour d'un service"
  hosts: all
  become: true

  tasks:
    - name: "Vérifier que le service est bien assigné à cette machine"
      ansible.builtin.assert:
        that:
          - target_service in machine_services
        fail_msg: >
          Le service '{{ target_service }}' n'est pas assigné à cette machine.
          Services disponibles : {{ machine_services | join(', ') }}

    - name: "Pull la nouvelle image et redémarrer"
      community.docker.docker_compose_v2:
        project_src: "/opt/modules/{{ target_service }}"
        pull: always
        state: present
      environment:
        IMAGE_VERSION: "{{ target_version }}"
```

---

## Bonnes pratiques rappel

```
1. Un rôle ne modifie JAMAIS les fichiers d'un autre rôle
2. Chaque rôle est testable seul (pas de dépendance cachée)
3. Les handlers sont dans le rôle qui les utilise
4. Les variables sont préfixées par le nom du rôle
5. Les secrets sont dans *_vault.yml, jamais en clair
6. Le .env est mode 0600, owner root — le user deploy ne peut pas le lire
7. Chaque compose est autonome — docker compose up fonctionne seul
8. Le code est lisible par un junior : noms explicites, une action par task
```
