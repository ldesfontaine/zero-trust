# Rôle : docker

## Objectif
Installe Docker Engine + configure le daemon (log rotation) + déploie le socket-proxy Tecnativa. Fournit `socket-proxy-net` comme réseau partagé.

## Architecture
1. `engine.yml` — installe `docker-ce` + CLI + containerd + compose plugin depuis le repo officiel Docker
2. `daemon.yml` — écrit `/etc/docker/daemon.json` avec log rotation (évite saturation disque sur long run)
3. `socket_proxy.yml` — déploie le container `tecnativa/docker-socket-proxy` avec permissions API minimales (`POST=0`, `EXEC=0`, `VOLUMES=0`). Crée le réseau `socket-proxy-net` (seul réseau `external: true` du projet).

## Dépendances
- Rôle requis : `base` (nftables doit autoriser le trafic Docker)
- Aucun secret vault

## Variables
Voir `defaults/main.yml`. Principales :
- `docker_socket_proxy_version`
- `docker_socket_proxy_permissions` — dict granulaire des endpoints API autorisés

## Utilisation
Dans `playbooks/site.yml` après `base` :
```yaml
roles:
  - role: docker
    tags: [docker]
```

Tout autre rôle qui a besoin de l'API Docker (Traefik pour le provider docker) se connecte à `socket-proxy-net` au lieu de monter `/var/run/docker.sock` directement.

## Contrats respectés
- Pas de `docker.sock` monté dans les containers applicatifs — passage via socket-proxy
- Exception : socket-proxy ne supporte PAS `read_only: true` (haproxy écrit sa config au démarrage) — sécurité via permissions API, pas filesystem
- `healthcheck` présent sur le container socket-proxy

## Testing
```bash
docker ps | grep socket-proxy
docker network ls | grep socket-proxy-net   # external, créé par ce rôle
curl --unix-socket /dev/null http://socket-proxy:2375/containers/json  # depuis un container du réseau
```
