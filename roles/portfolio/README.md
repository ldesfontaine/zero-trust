# Rôle : portfolio

## Objectif
Déploie le site portfolio statique (termfolio) derrière Traefik.

## Architecture
Container unique `ghcr.io/ldesfontaine/termfolio` pinné par version. Réseau `portfolio-net` (`internal: true` — pas de sortie internet requise). TLS géré par Traefik via labels Docker.

## Dépendances
- Rôles requis : `base`, `docker`, `traefik` (avant ce rôle)
- Secrets vault : aucun (site statique public)

## Variables
Voir `defaults/main.yml`.

## Utilisation
Dans `inventory/hosts.yml` :
```yaml
machine_services:
  - portfolio
  - ...
  - traefik   # toujours en dernier
```

Version pinnée dans `inventory/group_vars/all/versions.yml`.

## Contrats respectés
- Réseau `portfolio-net` (contrat A)
- Label `traefik.docker.network=portfolio-net` (contrat B)
- `internal: true` (pas d'exception justifiée)
- Hardening : `read_only`, `cap_drop: ALL`, `no-new-privileges`, `healthcheck`

## Testing
```bash
curl -sI https://portfolio.<base_domain>   # → 200, cert Let's Encrypt
docker ps | grep portfolio
docker logs portfolio --tail 20
```
