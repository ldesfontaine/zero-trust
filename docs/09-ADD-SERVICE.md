# 09 — Ajouter un service

Checklist complète pour intégrer un nouveau service (ex : seafile, immich, vaultwarden).
Ordonnée — ne pas sauter d'étape.

---

## 1. DNS

Cloudflare → Add record :
- Type : `A`
- Name : `<sous-domaine>`
- Content : IP du VPS
- Proxy : **DNS only** (nuage gris, pas orange)

Si le mode wildcard TLS est actif (`vault_cloudflare_dns_api_token` rempli), le cert `*.{{ base_domain }}` couvre automatiquement. Sinon, Traefik déclenchera HTTP-01 au premier accès.

---

## 2. Créer le rôle

```
roles/<service>/
├── defaults/main.yml
├── tasks/main.yml
├── templates/docker-compose.yml.j2
└── README.md
```

Copier `roles/portfolio/` (simple, sans secret) ou `roles/ntfy/` (non-root, secrets, token) comme base.

---

## 3. Variables (`defaults/main.yml`)

Toutes préfixées `<service>_`. Obligatoires :

```yaml
<service>_version: "X.Y.Z"           # surchargé par versions.yml
<service>_image: "org/image"
<service>_domain: "sub.{{ base_domain }}"
<service>_network_name: "<service>-net"
<service>_port: 8080
<service>_data_dir: "/opt/modules/<service>"
```

Container non-root :

```yaml
<service>_container_uid: 1000
<service>_container_gid: 1000
```

---

## 4. Template `docker-compose.yml.j2`

Contrats obligatoires (cf. `.claude/rules/docker.md`) :

- `image: ...:{{ version }}` — pinnée, jamais `latest`
- `security_opt: [no-new-privileges:true]`
- `cap_drop: [ALL]`
- `read_only: true` + `tmpfs: [/tmp]` si possible
- `healthcheck:` présent
- Labels Traefik avec pattern conditionnel wildcard :
  ```jinja
  - "traefik.http.routers.<service>.tls=true"
  {% if not traefik_wildcard_enabled %}
  - "traefik.http.routers.<service>.tls.certresolver=letsencrypt"
  {% endif %}
  ```
- `traefik.docker.network={{ <service>_network_name }}` (contrat B)
- Réseau avec `name: {{ <service>_network_name }}` explicite (contrat A)
- `internal: true` par défaut — `false` uniquement avec justification (cf. `docker.md` exceptions)

---

## 5. Tasks `main.yml`

Squelette minimal :

```yaml
- name: "<Service> — Creer le repertoire parent du module"
  ansible.builtin.file:
    path: "{{ <service>_data_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: "<Service> — Creer les sous-dossiers de donnees"
  ansible.builtin.file:
    path: "{{ <service>_data_dir }}/{{ item }}"
    state: directory
    owner: "{{ <service>_container_uid }}"
    group: "{{ <service>_container_gid }}"
    mode: "0750"
  loop: [data, cache]

- name: "<Service> — Verifier le drift reseau"
  ansible.builtin.include_tasks: "{{ playbook_dir }}/../roles/_shared/tasks/check_network_drift.yml"
  vars:
    network_name: "{{ <service>_network_name }}"
    network_internal: true   # ou false + justification

- name: "<Service> — Deployer le docker-compose"
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: "{{ <service>_data_dir }}/docker-compose.yml"
    owner: root
    group: root
    mode: "0644"
  notify: Redemarrer <service>

- name: "<Service> — Lancer le container"
  community.docker.docker_compose_v2:
    project_src: "{{ <service>_data_dir }}"
    state: present
```

Handler dans `handlers/main.yml` :
```yaml
- name: Redemarrer <service>
  community.docker.docker_compose_v2:
    project_src: "{{ <service>_data_dir }}"
    state: restarted
```

---

## 6. Secrets

```bash
ansible-vault edit inventory/host_vars/<machine>/vault.yml
```

Variables préfixées `vault_<service>_`. Jamais en clair.
`no_log: true` sur toute task qui manipule un secret.

---

## 7. Version dans `versions.yml`

`inventory/group_vars/all/versions.yml` :

```yaml
<service>_version: "X.Y.Z"
```

Source de vérité unique des versions — surcharge les defaults.

---

## 8. Activer dans l'inventaire

`inventory/hosts.yml` :

```yaml
machine_services:
  - portfolio
  - <service>      # nouveau
  - traefik        # TOUJOURS en dernier
```

Traefik en dernier car il se connecte aux réseaux des services déjà déployés (cf. `ansible-patterns.md` — `flush_handlers` + `connect_networks.yml`).

---

## 9. README du rôle

Créer `roles/<service>/README.md`. Gabarit dans les rôles existants (objectif, archi, dépendances, variables, utilisation, contrats respectés, testing). Garder < 50 lignes.

---

## 10. Déployer

```bash
# Dry-run obligatoire
ansible-playbook playbooks/site.yml --limit <machine> \
  --ask-vault-pass --check --diff

# Valider le diff, puis relancer sans --check
ansible-playbook playbooks/site.yml --limit <machine> --ask-vault-pass
```

---

## 11. Vérifier

```bash
curl -sI https://<sous-domaine>.<base_domain>   # → 200
docker ps | grep <service>
docker logs <service> --tail 20
```

Idempotence (non négociable) : relancer le playbook, attendre `changed=0`. Sinon la commande de check de présence est mal ciblée (cf. bug tokens ntfy dans `ansible-patterns.md`).

---

## Checklist mentale

- [ ] DNS record Cloudflare (DNS only, nuage gris)
- [ ] Rôle créé (`defaults`, `tasks`, `template`, `handlers`, `README`)
- [ ] Contrats réseau respectés (A nommage, B label)
- [ ] Container hardening (`cap_drop`, `no-new-privileges`, `read_only` si possible)
- [ ] `healthcheck` présent
- [ ] Secrets dans vault, `no_log: true`
- [ ] Version dans `versions.yml`
- [ ] `machine_services` mis à jour (+ `traefik` en dernier)
- [ ] README du rôle
- [ ] Test dry-run OK (diff cohérent)
- [ ] Test post-deploy OK (curl + logs)
- [ ] Idempotence confirmée (2ème run = 0 changed)
