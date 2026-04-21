# Rôle : traefik

## Objectif
Reverse proxy TLS avec auto-détection HTTP-01 / DNS-01 wildcard. Deux modes : `edge` (VPS, internet) ou `internal` (Pi, mesh only).

## Architecture
Un seul rôle, deux comportements selon `traefik_mode` :

### Mode `edge` (VPS)
- Écoute `0.0.0.0:80/443`
- Challenge HTTP-01 par défaut ; DNS-01 wildcard auto-activé si `vault_cloudflare_dns_api_token` présent (>10 chars)
- WAF + CrowdSec activables (`traefik_enable_waf`, `traefik_enable_crowdsec`)

### Mode `internal` (Pi)
- Écoute sur IP mesh (fact `traefik_mesh_ip`, fetch automatique depuis `wt0` au démarrage du rôle), pas de port 80 exposé
- Challenge DNS-01 **obligatoire** (pas d'HTTP-01 possible sans port 80 public)
- `fail` early si `vault_cloudflare_dns_api_token` absent
- Autonome : pas de dépendance au rôle `netbird` dans le play (pas besoin d'ordre client→traefik)

## tasks_from

- (défaut) `main.yml` — déploie Traefik, génère dynamic config, connecte aux réseaux
- `connect_networks.yml` — reconnecte Traefik aux réseaux de `machine_services` + `traefik_extra_networks` après déploiement des services (appelé depuis `site.yml` play 3)

## Dépendances
- Rôles requis : `base`, `docker`
- Secrets vault : `vault_cloudflare_dns_api_token` (optionnel en mode `edge`, obligatoire en `internal`)
- Variables globales : `base_domain`, `traefik_wildcard_enabled` (dérivée dans `group_vars/all/main.yml`)

## Variables
Voir `defaults/main.yml`. Ne JAMAIS réintroduire `traefik_tls_challenge` ou `traefik_dns_provider` manuels — auto-détection = source de vérité unique (cf. `tls.md`).

## Utilisation
Déployé AVANT les services applicatifs (play 2 de `site.yml`) car NetBird a besoin du domaine routable.

```yaml
- ansible.builtin.include_role:
    name: traefik
  when: "'traefik' in machine_services"
```

Reconnexion aux réseaux après services (play 3) :
```yaml
- ansible.builtin.include_role:
    name: traefik
    tasks_from: connect_networks.yml
```

## Contrats respectés
- TLS auto-détection (`tls.md`) — pas de `certresolver` en mode wildcard, obligatoire en HTTP-01
- Réseau `traefik-net` (contrat A) — mais Traefik se connecte aussi à tous les `<service>-net` via `connect_networks.yml`
- `meta: flush_handlers` obligatoire avant `docker_network` connect (cf. `ansible-patterns.md`)

## Testing
```bash
# Cert délivré (edge + wildcard)
curl -sI https://<any-sub>.<base_domain> | grep -i "server\|strict-transport"

# Dashboard Traefik (si exposé)
docker logs traefik 2>&1 | grep -i "certificate obtained"

# Réseaux connectés
docker network inspect portfolio-net | jq '.[].Containers | keys'  # doit contenir traefik
```
