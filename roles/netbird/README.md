# Rôle : netbird

## Objectif
Orchestrateur mesh WireGuard (serveur + config ACLs + agent client) en un seul rôle copier-collable.

## Architecture
Trois entrées distinctes activées via `tasks_from`, jamais via appel direct :
- `server.yml` : déploie NetBird Server (management + signal + relay + STUN) et le dashboard UI dans 2 containers Docker, derrière Traefik Edge. Seul port exposé hors Docker : UDP 3478 (STUN, `0.0.0.0`).
- `config.yml` : crée les groupes (`admin`, `dmz`, `private`, `agents`) et les 6 policies ACLs via l'API REST. Supprime la policy Default. Idempotent (skip si `vault_netbird_api_token` absent).
- `client/main.yml` : installe le paquet `netbird` (repo APT officiel) sur le host, enroll le nœud (setup key manuelle via `-e` ou auto via API), expose l'IP mesh comme fact `netbird_client_ip`.

Réseau Docker `netbird-server-net` — `internal: false` (relay doit sortir sur internet, cf. `docker.md`).

## Dépendances
- Rôles requis : `base`, `docker`, `traefik` (déployé AVANT ce rôle car le domaine doit être routable pour l'API)
- Secrets vault : `vault_netbird_auth_secret`, `vault_netbird_store_encryption_key`, `vault_netbird_auth_owner_email`, `vault_netbird_auth_owner_password` (server), `vault_netbird_api_token` (config + client mode auto)
- Variables globales : `netbird_domain`, `base_domain`, `base_ssh_port`, `traefik_wildcard_enabled`

## Variables
Voir `defaults/main.yml`. Préfixes conservés :
- `netbird_server_*` pour server
- `netbird_config_*` pour config
- `netbird_client_*` pour client

## Utilisation

Dans `inventory/hosts.yml`, activer les rôles par machine :
```yaml
machine_mesh:
  server: true   # VPS uniquement → server.yml + config.yml
  client: true   # tout nœud dans le mesh → client/main.yml
```

Dans `playbooks/site.yml` :
```yaml
- include_role: { name: netbird, tasks_from: server.yml }
  when: machine_mesh.server | default(false)

- include_role: { name: netbird, tasks_from: config.yml }
  when: machine_mesh.server | default(false)

- include_role: { name: netbird, tasks_from: client/main.yml }
  when: machine_mesh.client | default(false)
```

Appel direct (`include_role: { name: netbird }`) → `fail` explicite. Voir `tasks/main.yml`.

## Contrats respectés
- Réseau `netbird-server-net` (contrat A) — listé dans `traefik_extra_networks` car déployé via `machine_mesh`, pas via `machine_services`
- Label `traefik.docker.network=netbird-server-net` (contrat B)
- `internal: false` justifié dans `docker.md` (relay STUN/TURN public)

## Testing
```bash
# Server
docker ps | grep netbird
curl -sI https://netbird.<base_domain>/api/groups  # doit répondre 401 sans token

# Config (après bootstrap, token vault rempli)
curl -s -H "Authorization: Token $TOKEN" https://netbird.<base_domain>/api/groups | jq '.[].name'
# → admin, dmz, private, agents

# Client
netbird status   # → Connected
ip -4 addr show wt0  # → 100.64.x.x
```

Idempotence : relancer, attendre `changed=0`.
