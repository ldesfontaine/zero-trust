# 04 — Securite

## Principes partout

- Secrets en `.env` mode 0600, JAMAIS en dur dans un compose
- Containers : `no-new-privileges: true` + `cap_drop: [ALL]` + healthcheck
- Containers stateless : `read_only: true` + `tmpfs: [/tmp]`
- Binding : services prives sur `{{ netbird_bind_ip }}`, monitoring sur `127.0.0.1`
- Images : versions epinglees (JAMAIS `latest`), pre-buildees GHCR, pas de build en prod

---

## Couche 1 — Firewall

**VPS (nftables) — 4 ports :**
```
policy drop → SSH custom, 80, 443, 3478 → counter drop
```
- `delete table inet filter` puis recreer (JAMAIS `flush ruleset`)
- Docker/CrowdSec/NetBird gerent leurs propres tables
- Forward Docker : DNS/HTTP/HTTPS sortant uniquement

**Pi (UFW) :**
```
default deny → SSH custom limit (rate limit brute-force, 6 connexions/30s), DNS 53 incoming deny
```
UFW utilise `rule: limit` (pas juste `allow`) pour SSH — protection brute-force integree.

## Couche 2 — CrowdSec

LAPI (Docker) + bouncer (hote nftables). `deny_action: DROP` (silencieux).
Sources : Traefik (parser dedie), Docker wildcard, journald SSH, syslog.

**Whitelist admin :** `crowdsec/config/parsers/s02-enrich/admin-whitelist.yaml` avec `vault_admin_public_ip`. Evite l'auto-ban. Voir `08-DISASTER-RECOVERY.md` scenario E si banni.

## Couche 3 — Traefik middlewares

```yaml
security-headers   → TOUS les routers (HSTS, XSS, frame, nosniff, Permissions-Policy)
netbird-only       → routers VPN-only (whitelist 100.64.0.0/10)
rate-limit-public  → routers publics (50 req/min, burst 100)
Ntfy               → security-headers seul (public, auth geree par Ntfy)
```

Matrice complete : voir `02-ROLES.md` section backbone.

## Couche 4 — Ntfy auth token

Public (push phone sans VPN) avec `NTFY_AUTH_DEFAULT_ACCESS=deny-all`. Tout acces necessite un Bearer token. Scripts alerting/backup utilisent `Authorization: Bearer {{ vault_ntfy_auth_token }}`.

## Couche 5 — Reseau Docker

**Pi :**
```
brain_public   : BentoPDF, Portfolio
brain_services : Seafile+DB+memcached, Immich+DB+Redis (donnees utilisateur)
brain_infra    : AdGuard, Bientot, veille-secu, node-exporter, docker-proxy (monitoring/infra)
brain_vault    : Vaultwarden SEUL (isole)
```

**VPS :**
```
sentinel_net   : Traefik, NetBird, CrowdSec, Ntfy, bientot-agent, docker-proxy
```

## Couche 6 — Docker socket proxy

**VPS ET Pi** : le socket Docker n'est JAMAIS monte directement dans les containers applicatifs.
Un proxy `tecnativa/docker-socket-proxy` expose uniquement les endpoints lecture (CONTAINERS, NETWORKS, VOLUMES, INFO, EVENTS). Toutes les operations d'ecriture (POST, BUILD, EXEC, etc.) sont desactivees.

- VPS : docker-proxy dans `sentinel_net` (utilise par Traefik et CrowdSec/bientot-agent)
- Pi : docker-proxy dans `brain_infra` (utilise par bientot-agent Pi)

## Couche 7 — SSH

Port custom, Ed25519, password off, root off, MaxAuthTries 3, AllowTcpForwarding no, LogLevel VERBOSE, algo modernes.

## Couche 8 — Sudoers deploy restreint

Le user `deploy` (CI/CD) a des droits sudo **strictement limites** :
- `docker compose up/down/pull/ps` uniquement sur `/opt/*/docker-compose.yml`
- `ansible-playbook` uniquement dans le repo deploye
- `git` uniquement dans le repo deploye
- **Pas de sudo complet**, pas d'acces UFW/nftables/SSH

Si la cle deploy est compromise, l'attaquant peut redemarrer des services mais ne peut PAS modifier le firewall, SSH, ou obtenir un shell root.

## Couche 9 — NetBird ACL deny-by-default

5 policies, Default supprimee. Guard anti-lockout. Groupe `infra` scalable. Flux unidirectionnels sauf admins et ICMP. Detail dans `01-MACHINES.md`.

---

## Supply chain

- Images applicatives : signees cosign, verifiees avant pull
- Scanner CVE : Grype (Anchore) — Trivy retire suite a compromission TeamPCP mars 2026
- GitHub Actions : pinned sur commit SHA (pas sur tags mutables)
- Images perso : GitHub Actions multi-arch → GHCR → pull Ansible
- `go mod verify` dans Dockerfiles Go
- Dependabot gomod + docker weekly

## Docker logs

Rotation dans `daemon.json` (role `docker`) :
```json
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
```

## Backup 3-2-1

| Copie | Support | Chiffrement |
|-------|---------|-------------|
| ZFS mirror NVMe | Pi | Hardware |
| SSD USB air-gapped | Physique | LUKS |
| VPS off-site | Reseau | GPG asymetrique |

**Dead man's switch** : les scripts de backup (`backup-vps.sh`, `backup-usb.sh`) ont un `trap ERR` qui notifie via Ntfy en cas d'echec. Si un backup echoue silencieusement, le monitoring detecte l'absence de fichier de statut recent et alerte.

Detail dans `08-DISASTER-RECOVERY.md`. Gestion cles dans `09-SECRETS.md`.
