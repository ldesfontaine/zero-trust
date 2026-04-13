# 01 — Machines

## Sentinelle (VPS)

**Rôle :** DMZ publique. Zéro donnée utilisateur. Recréable via Terraform.

### Filesystem

```
/opt/backbone/                          ← Rôle: backbone
├── docker-compose.yml                     Traefik + NetBird server + dashboard
├── traefik/dynamic/traefik-services.yml   Routes vers Pi
└── netbird/data/ + netbird_config.yaml

/opt/sentinel/                          ← Rôle: services-vps
├── docker-compose.yml                     CrowdSec, Ntfy, node-exporter, bientot-agent
├── .env                                   Secrets (mode 0600)
├── crowdsec/config/ + data/
│   └── parsers/s02-enrich/admin-whitelist.yaml
├── ntfy/
└── acquis.yaml

/etc/nftables.conf                      ← Rôle: base-vps
/etc/ssh/sshd_config                    ← Rôle: base-vps
NetBird client (systemd)                ← Rôle: netbird-client
CrowdSec bouncer (systemd)             ← Rôle: services-vps
```

### Ports internet (nftables)

| Port | Proto | Service |
|------|-------|---------|
| `{{ vault_ssh_port }}` | TCP | SSH Ed25519 |
| 80 | TCP | HTTP → redirect HTTPS |
| 443 | TCP | HTTPS (Traefik) |
| 3478 | UDP | NetBird STUN/TURN |

**4 ports.** Minimum incompressible.

### Containers (sentinel_net)

| Container | Image | Déployé par |
|-----------|-------|-------------|
| traefik | `traefik:{{ version }}` | backbone |
| netbird-server | `netbirdio/netbird:{{ version }}` | backbone |
| netbird-dashboard | `netbirdio/dashboard:{{ version }}` | backbone |
| crowdsec | `crowdsecurity/crowdsec:{{ version }}` | services-vps |
| ntfy | `binwiederhier/ntfy:{{ version }}` | services-vps |
| node-exporter | `prom/node-exporter:{{ version }}` | services-vps |
| bientot-agent | `ghcr.io/ldesfontaine/bientot-agent:{{ version }}` | services-vps |

---

## Cerveau (Raspberry Pi 5)

**Rôle :** Données privées. Zéro port internet. Mesh uniquement.

### Filesystem

```
/mnt/tank/stack/                        ← Rôle: services-pi (ZFS mirror NVMe)
├── docker-compose.yml
├── .env                                   Secrets (mode 0600)
├── seafile/data/ + db/
├── vaultwarden/                           SQLite intégré
├── immich/upload/ + db/ + model-cache/
├── adguard/conf/ + work/
├── bientot/data/
└── backup/status/ + staging/

/etc/ssh/sshd_config                    ← Rôle: base-pi
NetBird client (systemd)                ← Rôle: netbird-client
```

### Ports (bind `{{ netbird_bind_ip }}` uniquement)

| Port | Service | Réseau Docker | Accès |
|------|---------|---------------|-------|
| 8090 | BentoPDF | brain_public | Public via VPS |
| 8091 | Portfolio | brain_public | Public via VPS |
| 8092 | Seafile | brain_private | VPN-only |
| 8093 | Vaultwarden | **brain_vault** | VPN-only |
| 8094 | Immich | brain_private | VPN-only |
| 5353 | AdGuard DNS | brain_private | Mesh DNS |
| 3000 | AdGuard UI | brain_private | VPN-only |
| 3001 | Bientôt dashboard | brain_private | VPN-only (Traefik) |
| 3002 | Bientôt agents | brain_private | Mesh direct (PAS Traefik) |
| 9100 | node-exporter | brain_private | Localhost only |

### Réseaux Docker

```
brain_public   ← BentoPDF, Portfolio (publics via VPS)
brain_private  ← Seafile+DB, Immich+DB+Redis, AdGuard, Bientôt, veille-secu, node-exporter
brain_vault    ← Vaultwarden SEUL (isolé, SQLite intégré)
```

### Containers

| Container | Image | Réseau |
|-----------|-------|--------|
| bentopdf | `{{ bentopdf_image }}:{{ version }}` | brain_public |
| portfolio | `ghcr.io/ldesfontaine/termfolio:{{ version }}` | brain_public |
| seafile + seafile-db + memcached | Docker Hub | brain_private |
| vaultwarden | Docker Hub | **brain_vault** |
| immich-server + immich-db + immich-redis | GHCR | brain_private |
| adguard | Docker Hub | brain_private |
| bientot-server | `ghcr.io/ldesfontaine/bientot-server:{{ version }}` | brain_private |
| bientot-agent | `ghcr.io/ldesfontaine/bientot-agent:{{ version }}` | brain_private |
| veille-secu | `ghcr.io/ldesfontaine/veille-secu:{{ version }}` | brain_private |
| node-exporter | Docker Hub | brain_private |

---

## ACLs NetBird

```
admins       ↔  sentinelle     : ALL
admins       ↔  cerveau        : ALL
infra        →  cerveau        : TCP 8090-8094, 3000, 3001, 3002
cerveau      →  sentinelle     : TCP 443, {{ vault_ssh_port }}
sentinelle   ↔  cerveau        : ICMP
Default                         : SUPPRIMÉE
```

Groupe `infra` = sentinelle + futures machines (scalable).

---

## DNS A records (tous → IP publique VPS)

```
mesh.domain.com          ← NetBird dashboard
pdf.domain.com           ← BentoPDF (public)
portfolio.domain.com     ← Portfolio (public)
cloud.domain.com         ← Seafile (VPN-only, rewrite AdGuard)
vault.domain.com         ← Vaultwarden (VPN-only, rewrite AdGuard)
photos.domain.com        ← Immich (VPN-only, rewrite AdGuard)
adguard.domain.com       ← AdGuard UI (VPN-only, rewrite AdGuard)
bientot.domain.com       ← Bientôt (VPN-only, rewrite AdGuard)
ntfy.domain.com          ← Ntfy (public, auth token)
```

Si le VPS change d'IP → mettre à jour TOUS ces records chez le registrar.
