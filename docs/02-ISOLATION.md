# 02 — Isolation & liens entre services

## Docker daemon — configuration globale

Identique sur toutes les machines :

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

Docker gère le NAT automatiquement :
  - Réseaux `internal: true` → pas de MASQUERADE → pas de sortie internet
  - Réseaux non-internal → MASQUERADE → sortie internet
  - nftables gère le trafic HOST (INPUT/OUTPUT), pas le trafic Docker (FORWARD)

---

## Modèle d'isolation réseau

```
Chaque service crée son propre réseau Docker (internal: true).
Traefik rejoint CHAQUE réseau service individuellement.
Aucun réseau partagé entre services.

Un service compromis ne voit QUE ses propres containers.
Traefik est le SEUL pont entre les services.
```

### Comment Traefik se connecte

```
1. Chaque rôle service fait docker compose up → crée son réseau
2. Le rôle Traefik boucle sur machine_services
3. Pour chaque service, il exécute :
     docker network connect <service>-net traefik-<mode>
4. Traefik lit les labels Docker via le socket proxy
5. Traefik crée les routes automatiquement

Si un nouveau service est ajouté dans 5 mois :
  → Ajouter dans machine_services + créer le rôle
  → Le rôle Traefik se connecte automatiquement au nouveau réseau
  → Zéro modification dans les autres services
```

### Seul réseau pré-créé par Ansible

```
socket-proxy-net (internal: true)
  → Créé AVANT les services car utilisé par Traefik + Bientôt Agent
  → C'est le SEUL réseau qui ne vient pas d'un docker compose
```

---

## DMZ-01 (VPS) — réseaux Docker

```
socket-proxy-net (internal: true) ← pré-créé par Ansible
  └── Docker Socket Proxy
      Rejoint par : Traefik Edge, Bientôt Agent

portfolio-net (internal: true) ← créé par compose portfolio
  ├── Portfolio (read-only)
  └── Traefik Edge             ← connecté par le rôle Traefik

ntfy-net (internal: true) ← créé par compose ntfy
  ├── Ntfy
  └── Traefik Edge             ← connecté par le rôle Traefik

bentopdf-net (internal: true) ← créé par compose bentopdf
  ├── BentoPDF (read-only)
  └── Traefik Edge             ← connecté par le rôle Traefik

crowdsec-net (internal: false) ← créé par compose crowdsec
  └── CrowdSec + bouncer host
      Non-internal : doit appeler l'API CrowdSec Central
      Logs Traefik Edge : via volume read-only, PAS via réseau

netbird-net (internal: false) ← créé par compose netbird
  └── NetBird Server
      Non-internal : STUN/TURN public

monitoring-net (internal: true) ← créé par compose bientot-agent
  └── Bientôt Agent
      Aussi sur socket-proxy-net
```

Isolation :
  - Portfolio ne voit PAS Ntfy (réseaux différents)
  - Ntfy ne voit PAS BentoPDF (réseaux différents)
  - Seuls CrowdSec et NetBird peuvent sortir sur internet (non-internal)
  - Tout le reste est bloqué (internal: true)

---

## PRIV-01 (Pi) — réseaux Docker

```
AUCUN réseau non-internal sur le Pi.
Aucun container ne peut sortir sur internet.

socket-proxy-net (internal: true) ← pré-créé par Ansible
  └── Docker Socket Proxy
      Rejoint par : Bientôt Agent

seafile-net (internal: true) ← créé par compose seafile
  ├── Seafile + Seafile-DB + Memcached
  └── Traefik Internal         ← connecté par le rôle Traefik

vaultwarden-net (internal: true) ← créé par compose vaultwarden
  ├── Vaultwarden (SQLite)
  └── Traefik Internal         ← connecté par le rôle Traefik

immich-net (internal: true) ← créé par compose immich
  ├── Immich + Immich-DB + Immich-Redis
  └── Traefik Internal         ← connecté par le rôle Traefik

adguard-net (internal: true) ← créé par compose adguard
  ├── AdGuard Home
  │   DNS :53 bindé sur IP mesh (hors Traefik)
  └── Traefik Internal         ← connecté pour l'UI web

veille-net (internal: true) ← créé par compose veille-secu
  ├── Veille Sécu + DB
  └── Traefik Internal         ← connecté par le rôle Traefik

bientot-net (internal: true) ← créé par compose bientot-master
  ├── Bientôt Master
  │   Agent API :3002 bindé sur IP mesh (hors Traefik)
  └── Traefik Internal         ← connecté pour le dashboard

monitoring-net (internal: true) ← créé par compose bientot-agent
  └── Bientôt Agent
      Aussi sur socket-proxy-net
```

Isolation identique au VPS : aucun service ne voit un autre service.

---

## Bases de données — règle absolue

Aucune DB n'a de port exposé. La DB existe uniquement sur le réseau interne de son service.

| DB | Réseau | Accessible par |
|----|--------|---------------|
| Seafile-DB (MariaDB) | seafile-net | Seafile uniquement |
| Immich-DB (Postgres) | immich-net | Immich uniquement |
| Immich-Redis | immich-net | Immich uniquement |
| Veille-DB (SQLite/Postgres) | veille-net | Veille Sécu uniquement |
| Vaultwarden | SQLite fichier | Pas de DB réseau |

---

## Docker Socket Proxy

Un proxy par machine. Réseau dédié `socket-proxy-net` (`internal: true`).

```
Permissions :
  CONTAINERS=1   IMAGES=1   NETWORKS=1   INFO=1   EVENTS=1
  EXEC=0         POST=0     VOLUMES=0

Consommateurs :
  VPS : Traefik Edge (Docker provider) + Bientôt Agent
  Pi  : Bientôt Agent uniquement
```

---

## CrowdSec — accès aux logs

CrowdSec lit les logs via volume Docker read-only, PAS via réseau.

```
Traefik Edge  → écrit → /var/log/traefik/access.log
                              ↓ volume :ro
CrowdSec      → lit   → /var/log/traefik/access.log

Sources :
  1. Logs Traefik Edge (access logs) — tout le trafic HTTP
  2. Logs SSH du host (auth.log) — brute force
  3. C'est tout. Pas de logs applicatifs individuels.
```

---

## Ports exposés sur le mesh (Pi)

| Port | Service | Qui y accède |
|------|---------|-------------|
| 100.64.x.x:443 | Traefik Internal | Admin uniquement (ACL NetBird) |
| 100.64.x.x:53 | AdGuard DNS | Tous les peers mesh |
| 100.64.x.x:3002 | Bientôt Master (agent API) | Agents de tous les nœuds (auth token) |

**3 ports. C'est tout.** Tous les services applicatifs sont derrière Traefik Internal.
