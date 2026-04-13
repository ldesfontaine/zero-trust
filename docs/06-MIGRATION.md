# 06 — Migration depuis l'ancienne structure

> **Instructions Claude Code. Étape par étape. Valider chaque étape.**

## Mapping ancien → nouveau (21 → 12 rôles)

```
system-vps + hardening-vps        →  base-vps
system-pi + hardening-pi          →  base-pi
docker                            →  docker (+ log rotation daemon.json)
traefik + netbird-server          →  backbone (+ middlewares sécu)
netbird-client + netbird-resolve  →  netbird-client
netbird-acl + netbird-dns
  + adguard-dns                   →  mesh-config (+ groupe infra)
stack-vps + crowdsec-bouncer      →  services-vps (+ bientot-agent + whitelist CrowdSec)
stack-pi + bientot + veille-secu  →  services-pi (images GHCR, plus de git clone)
backup-zfs                        →  backup (+ trap ERR + Bientôt DB)
alerting + image-maintenance      →  monitoring (+ Trivy JSON + auth Ntfy)
connection-resolver               →  connection-resolver (inchangé)

SUPPRIMÉ : adguard-exporter (Bientôt module natif le remplace)
```

Anciens playbooks supprimés : `infrastructure.yml` (ancien), `services.yml` (ancien), `operations.yml`, `onboard.yml`
Nouveaux : `infrastructure.yml` (nouveau), `services.yml` (nouveau), `mesh-config.yml`, `site.yml`

---

## Étape 1 — Arborescence
```bash
mkdir -p roles/{common,base-vps,base-pi,backbone,mesh-config,services-vps,services-pi,backup,monitoring}/{tasks,templates,handlers,defaults,meta,files}
```

## Étape 2 — `common`
Extraire de `system-vps` + `system-pi` : apt update/upgrade, reset_connection, packages (+ **jq**), unattended-upgrades.

## Étape 3 — `base-vps`
Fusionner `system-vps` + `hardening-vps`. Templates : `nftables.conf.j2`, `sshd_config.j2`. Handlers unifiés (plus de doublon). Changements templates :
- nftables : supprimer port 33073, supprimer ports mesh 9100/6060
- sshd : `AllowTcpForwarding no`

## Étape 4 — `base-pi`
Fusionner `system-pi` + `hardening-pi`. Même logique. `AllowTcpForwarding no`.

## Étape 5 — `docker`
Ajouter log rotation dans daemon.json :
```json
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
```

## Étape 6 — `backbone`
Fusionner `traefik` + `netbird-server`. SUPPRIMER `stack-vps/templates/traefik_dynamic_yml.j2` (doublon). Renommer → `traefik-services.yml.j2`. Ajouter middlewares :
- `security-headers` (HSTS, XSS, frame, nosniff, Permissions-Policy)
- `rate-limit-public` (50 req/min)
- Appliquer sur tous les routers selon type (voir `04-SECURITY.md`)
- Ntfy : `security-headers` seul (PAS netbird-only)

## Étape 7 — `netbird-client`
Fusionner avec `netbird-resolve`. Créer `tasks/resolve.yml` séparé.

## Étape 8 — `mesh-config`
Fusionner `netbird-acl` + `netbird-dns` + `adguard-dns`. Changements :
- Créer groupe `infra` (sentinelle + futures machines)
- 5 policies : admins↔sentinelle, admins↔cerveau, infra→cerveau (TCP 8090-8094,3000,3001,**3002**), cerveau→sentinelle (TCP **443**,SSH), ICMP
- Supprimer ancienne policy monitoring (9100/6060)

## Étape 9 — `services-vps`
Fusionner `stack-vps` + `crowdsec-bouncer`. Changements :
- Créer `sentinel.env.j2` (mode 0600), migrer secrets du compose vers .env
- `cap_drop: [ALL]` partout. Traefik : `cap_add: [NET_BIND_SERVICE]`
- node-exporter : bind `127.0.0.1:9100` (plus mesh)
- CrowdSec metrics : bind `127.0.0.1:6060` (plus mesh)
- Ajouter `bientot-agent` (image GHCR, push-only)
- Ntfy : `NTFY_AUTH_DEFAULT_ACCESS=deny-all`
- Créer `crowdsec-admin-whitelist.yaml.j2` avec `vault_admin_public_ip`

## Étape 10 — `services-pi`
Fusionner `stack-pi` + `bientot` + `veille-secu`. Changements :
- Créer `brain.env.j2` (mode 0600), migrer TOUS les secrets
- `cap_drop: [ALL]` partout
- `read_only: true` + `tmpfs` sur bentopdf et portfolio
- Vaultwarden sur réseau `brain_vault` (isolé)
- **SUPPRIMER** adguard-exporter (Bientôt module natif)
- Remplacer git clone par images GHCR : termfolio, bientot-server, bientot-agent, veille-secu
- **SUPPRIMER** le workaround lineinfile qui patchait le code Go de Bientôt

## Étape 11 — `backup` + `monitoring`
Renommer `backup-zfs` → `backup`. Fusionner `alerting` + `image-maintenance` → `monitoring`.
- Tous les curl Ntfy : ajouter `Authorization: Bearer`
- backup-vps.sh : ajouter `trap ERR` → notification échec
- Ajouter Bientôt DB aux données backupées
- Trivy : `--format json` + `jq`
- Seuil disk VPS : 80%

## Étape 12 — Nouveaux playbooks
Créer `infrastructure.yml`, `services.yml`, `mesh-config.yml` selon `03-WORKFLOW.md`.
```yaml
# site.yml
- import_playbook: infrastructure.yml
- import_playbook: services.yml
- import_playbook: mesh-config.yml
```
Supprimer anciens playbooks (sauf bootstrap.yml et restore.yml).
Mettre à jour restore.yml pour la nouvelle structure.

## Étape 13 — Config
- `ansible.cfg` : `StrictHostKeyChecking=accept-new`
- `group_vars/all.yml.example` : épingler versions `latest`, ajouter images GHCR
- `host_vars/vps_serv.yml.example` : ajouter `vault_admin_public_ip`, `vault_ntfy_auth_token`
- CI/CD workflows : mettre à jour noms de playbooks

## Étape 14 — Supprimer les anciens rôles
Après validation complète (`--check --diff` propre, services UP, healthchecks OK) :
```bash
rm -rf roles/{system-vps,system-pi,hardening-vps,hardening-pi,traefik,netbird-server,netbird-resolve,netbird-acl,netbird-dns,adguard-dns,stack-vps,stack-pi,crowdsec-bouncer,bientot,veille-secu,backup-zfs,alerting,image-maintenance}
```
