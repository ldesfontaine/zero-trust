# 00 — Vue d'ensemble

## Schéma réseau

```
                         Internet
                            │
                    ┌───────┴────────┐
                    │  SENTINELLE    │  VPS Debian 12 amd64
                    │  (DMZ)        │  IP publique
                    │               │
                    │  :80/443 ──── Traefik (TLS, headers, rate limit)
                    │  :3478 ────── NetBird STUN/TURN
                    │               │
                    │  CrowdSec ─── IDS/IPS (bouncer nftables hôte)
                    │  Ntfy ──────── Notifications (public + auth token)
                    │  bientot-agent  Métriques locales → push Pi
                    │               │
                    │  nftables ─── policy drop, 4 ports
                    └───────┬────────┘
                            │
                    Tunnel WireGuard chiffré E2E
                    (NetBird mesh, 100.64.x.x)
                            │
                    ┌───────┴────────┐
                    │  CERVEAU       │  Raspberry Pi 5 arm64
                    │  (LAN)        │  Zéro port internet
                    │               │
                    │  Seafile       Cloud personnel
                    │  Vaultwarden   Mots de passe (réseau isolé)
                    │  Immich        Photos/vidéos
                    │  AdGuard       DNS mesh + blocage pub
                    │  BentoPDF      PDF (public via VPS)
                    │  Portfolio     Site vitrine (public via VPS)
                    │  bientot-server Dashboard monitoring (VPN-only)
                    │  veille-secu   CVE (interne à Bientôt)
                    │  bientot-agent  Métriques locales → server
                    │               │
                    │  ZFS mirror    Données NVMe
                    │  UFW           SSH custom + deny DNS ext
                    └────────────────┘

Devices admin (laptop, phone)
    └── NetBird client → mesh → services privés
```

## Flux réseau

```
Visiteur internet  → HTTPS :443 → Traefik → mesh → Pi (BentoPDF/Portfolio)
Admin VPN          → NetBird → Traefik (whitelist 100.64/10) → mesh → Pi (services privés)
Notif phone        → HTTPS :443 → Traefik → Ntfy (auth token, sans VPN)
Agent VPS          → push HTTP → mesh → Pi:3002 (Bientôt server)
Agent Pi           → push HTTP → localhost:3002 (Bientôt server)
Backup Pi→VPS      → SSH/SCP → mesh → /opt/backups/ sur VPS
Alertes Pi→Ntfy    → curl HTTPS → mesh → VPS:443 → Ntfy
```

## Déploiement en 2 phases

```
Phase 1 — INFRASTRUCTURE        Phase 2 — SERVICES
(socle + mesh)                   (apps + config + opérations)
                    enrollment
 bootstrap ──►      manuel      ──► services
 infrastructure ──► NetBird     ──► mesh-config
                                ──► (backup, monitoring inclus)
```

L'enrollment NetBird est la frontière. Avant : les machines se préparent. Après : les services se déploient. Voir `docs/03-WORKFLOW.md`.
