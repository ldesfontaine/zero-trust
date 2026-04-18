# 03 — Flux réseau

## Vue d'ensemble

```
Internet ──HTTPS──→ VPS (Traefik Edge) ──→ services publics locaux
                                          Portfolio, BentoPDF, Ntfy

Admin ──NetBird──→ Pi (Traefik Internal) ──→ services privés
                                            Seafile, Vault, Immich, etc.

Agents ──mesh──→ Pi (Bientôt Master :3002) ──→ métriques + commandes

Pi ──mesh──→ VPS (Ntfy :443) ──→ alertes
Pi ──mesh──→ VPS (SSH :port) ──→ backup GPG
```

---

## Trafic internet → services publics

```
Visiteur → HTTPS :443
  → nftables (policy drop, accept :80 :443 :3478)
  → WAF Coraza (parse, valide, reconstruit)
  → Traefik Edge
  → route vers backend LOCAL uniquement :
    - portfolio.domain.fr  → Portfolio (portfolio-net)
    - ntfy.domain.fr       → Ntfy (ntfy-net)
    - pdf.domain.fr        → BentoPDF (bentopdf-net)

Traefik Edge ne route RIEN vers le Pi.
Aucun service privé n'est accessible depuis internet.
```

---

## Trafic admin → services privés

```
Admin (laptop/téléphone avec NetBird connecté)
  → DNS : AdGuard rewrite *.domain.fr → 100.64.x.x (IP mesh Pi)
  → HTTPS :443 → Pi Traefik Internal
  → route vers service demandé :
    - vault.domain.fr    → Vaultwarden
    - seafile.domain.fr  → Seafile
    - immich.domain.fr   → Immich
    - bientot.domain.fr  → Bientôt dashboard
    - adguard.domain.fr  → AdGuard UI
    - veille.domain.fr   → Veille Sécu

TLS géré par Traefik Internal (challenge DNS Let's Encrypt).
DNS public ne connaît PAS ces sous-domaines.
```

---

## Trafic monitoring (Bientôt)

```
Agent VPS → push HTTP POST → mesh → Pi:3002 /push (métriques)
          → WS            → mesh → Pi:3002 /ws   (commandes)

Agent Pi  → push HTTP POST → localhost:3002 /push
          → WS            → localhost:3002 /ws

Dashboard → NetBird → Pi Traefik Internal → bientot.domain.fr
```

---

## Trafic backup

```
Backup cron Pi → rsync via mesh → VPS:port_ssh → /opt/backups/
  Données : archives .tar.zst.gpg (chiffrées GPG)
  Fréquence : quotidien
  Le VPS stocke des blobs opaques
```

---

## Trafic sortant autorisé (output allowlist)

### VPS

| Destination | Port | Raison |
|-------------|------|--------|
| 9.9.9.9 / 1.1.1.1 | 53 | DNS public (pas AdGuard — DMZ jetable) |
| Let's Encrypt ACME | 443 | Certificats TLS |
| CrowdSec Central API | 443 | Listes communautaires |
| ghcr.io, registry.docker.io | 443 | Pull images Docker |
| Interface NetBird | mesh | Trafic zone privée |

### Pi

| Destination | Port | Raison |
|-------------|------|--------|
| Quad9 / Cloudflare | 53, 853 | AdGuard upstream DNS |
| ghcr.io, registry.docker.io | 443 | Pull images Docker |
| API DNS provider (Cloudflare/OVH) | 443 | Challenge DNS Let's Encrypt (Traefik Internal) |
| Interface NetBird | mesh | Trafic vers VPS/agents |

**RIEN D'AUTRE.** Tout le reste est bloqué par nftables output policy drop.

---

## Trafic interdit (enforcement)

```
- Pi → internet direct           : BLOQUÉ (nftables output drop)
- VPS → Pi par IP publique        : IMPOSSIBLE (Pi n'a pas d'IP publique)
- Container → internet (hors allowlist) : BLOQUÉ (internal: true + nftables)
- Container A → Container B       : IMPOSSIBLE (réseaux Docker séparés)
- Accès docker.sock direct        : IMPOSSIBLE (socket proxy only)
- VPS → services privés Pi        : BLOQUÉ (ACL NetBird)
```

---

## ACLs NetBird

### Groupes de peers

```
admin   → laptop, téléphone (tes devices perso)
dmz     → VPS (et futurs VPS)
private → Pi (et futurs nœuds privés)
agents  → tous les nœuds avec Bientôt Agent (dmz + private)
```

### Policies (additives dans NetBird)

**Règle : les policies admin → serveurs sont TOUJOURS unidirectionnelles (`bidirectional: false`).**
Un serveur compromis ne doit jamais pouvoir initier une connexion vers le laptop admin (anti-pivot).
Le laptop initie, les serveurs répondent — pas l'inverse.

```
POLICY 1 : admin → dmz (unidirectionnel)
  TOUT (SSH, dashboards, debug)

POLICY 2 : admin → private (unidirectionnel)
  TOUT (SSH, Traefik Internal :443, Bientôt :3002, DNS :53)

POLICY 3 : dmz → private (trafic applicatif)
  AdGuard DNS (:53) uniquement
  PAS de ports applicatifs — services privés mesh-only

POLICY 4 : agents → private (monitoring)
  Bientôt Agent → Master (:3002) uniquement
  Ne contredit PAS policy 3 : policies additives

POLICY 5 : private → dmz (alertes + backup)
  Ntfy via Traefik Edge (:443)
  SSH/rsync (:port_ssh) — backup GPG quotidien

dmz → dmz : pas de policy = deny-by-default (NetBird bloque implicitement)

POLICY 6 : private → private
  Bientôt Agent → Master (:3002) uniquement
```

### Impact d'un VPS compromis

```
L'attaquant est sur le mesh avec les droits du groupe "dmz".

Peut atteindre :
  - AdGuard DNS (:53) — empoisonnement DNS possible (risque limité)

NE PEUT PAS atteindre :
  - Traefik Internal (:443) — policy 3 ne l'autorise pas
  - Vaultwarden, Seafile, Immich — derrière Traefik Internal
  - Bientôt dashboard — derrière Traefik Internal
  - SSH du Pi — policy 3 ne l'autorise pas
  - AdGuard UI — derrière Traefik Internal
  - Laptop admin — policies 1 et 2 unidirectionnelles, pas de retour possible

Surface d'attaque depuis DMZ compromise : quasi nulle.
Pivot vers le laptop admin : impossible (bidirectional: false).
```
