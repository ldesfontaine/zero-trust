# 01 — Services

## DMZ-01 (VPS) — services publics et infra exposée

| Service | Rôle | Accès | Justification placement |
|---------|------|-------|------------------------|
| **Traefik Edge** | Reverse proxy, TLS (challenge HTTP), routing | TCP 80, 443 | Point d'entrée internet |
| WAF (Coraza) | Middleware Traefik Edge — parse/valide requêtes | intégré à Traefik Edge | Filtre avant routing |
| CrowdSec | IDS/IPS — bouncer nftables | interne | Détection attaques |
| NetBird Server | Orchestrateur mesh (management + STUN) | UDP 3478 | Enrollment peers (doit être public) |
| Ntfy | Notifications push (Bearer token) | via Traefik Edge | Push mobile fiable sans VPN |
| BentoPDF | Conversion PDF (stateless) | via Traefik Edge | Input non trusté → DMZ, pas zone privée |
| Portfolio | Site perso (statique) | via Traefik Edge | Contenu public, pas d'aller-retour mesh |
| Bientôt Agent | Monitoring local | interne | Push métriques vers Master (Pi) |
| Docker Socket Proxy | API Docker read-only | interne | Sécurise l'accès Docker pour Traefik + Agent |

**Ce qui n'est PAS sur le VPS** : aucune donnée utilisateur, aucun DNS, aucun service privé.

---

## PRIV-01 (Pi) — services privés et données

| Service | Rôle | Accès | Justification placement |
|---------|------|-------|------------------------|
| **Traefik Internal** | Reverse proxy mesh-only, TLS (challenge DNS) | 100.64.x.x:443 | TLS auto pour services privés |
| AdGuard Home | DNS mesh + blocage pub | 100.64.x.x:53 (DNS), UI via Traefik Int. | DNS privé en zone privée |
| Seafile | Cloud fichiers | via Traefik Internal | Données utilisateur → zone privée |
| Vaultwarden | Mots de passe | via Traefik Internal | Donnée la plus critique → zone privée, mesh-only |
| Immich | Photos/vidéos | via Traefik Internal | Données personnelles → zone privée |
| Veille Sécu | Collecteur CVE | via Traefik Internal | Alimente Bientôt CTI |
| Bientôt Master | Dashboard infra + réception agents | dashboard via Traefik Int., agent API :3002 direct mesh | Cerveau monitoring, zone protégée |
| Bientôt Agent | Monitoring local | interne | Push métriques vers Master localhost |
| Docker Socket Proxy | API Docker read-only | interne | Sécurise l'accès Docker pour Agent |

**Ce qui n'est PAS sur le Pi** : aucun service traitant de l'input non trusté, aucun contenu public direct.

---

## Traefik Edge vs Traefik Internal

```
                    Traefik Edge (VPS)       Traefik Internal (Pi)
                    ──────────────────       ─────────────────────
Écoute              0.0.0.0:443              100.64.x.x:443
Trafic              Internet hostile          Mesh chiffré (trusté)
WAF Coraza          Oui                       Non
CrowdSec            Oui                       Non
Rate limiting       Agressif                  Léger
Challenge TLS       HTTP-01                   DNS-01
Services            Portfolio, Ntfy, BentoPDF  Seafile, Vault, Immich, etc.
Rôle Ansible        traefik (mode: edge)       traefik (mode: internal)
```

Deux instances indépendantes. Même rôle Ansible, variables différentes. Elles ne se connaissent pas et ne se parlent pas.

---

## Modules — structure

### Un service = un dossier autonome

```
modules/
├── seafile/
│   ├── docker-compose.yml    # compose autonome, réseau isolé
│   ├── .env.j2               # template variables (secrets, ports, mesh IP)
│   └── README.md             # flux, dépendances, notes
├── vaultwarden/
│   ├── docker-compose.yml
│   ├── .env.j2
│   └── README.md
├── traefik/
│   ├── docker-compose.yml
│   ├── .env.j2
│   └── README.md             # mode edge ou internal selon la variable
└── ...
```

### Règles d'un module

1. Compose autonome — `docker compose up` fonctionne seul
2. Réseau Docker isolé (`internal: true`)
3. Pas de docker.sock — si besoin → socket-proxy-net
4. Ports bindés sur IP mesh — jamais 0.0.0.0 (sauf Traefik Edge)
5. Images GHCR ou Docker Hub — pas de git clone, pas de build serveur
6. Variables via .env — aucun secret dans le compose
7. `read_only: true` + `tmpfs` quand possible
8. Labels Traefik — routing automatique
9. Labels Bientôt — découverte automatique dans le dashboard

### Branchement / Débranchement

```
Brancher :                           Débrancher :
1. Ansible copie le module           1. docker compose down
2. Ansible template le .env          2. Ansible supprime le dossier
3. docker compose up -d              3. Disparaît du dashboard Bientôt
4. Découverte auto (labels)          4. Traefik retire la route
```

---

## Bientôt — modèle de communication

```
MÉTRIQUES (Agent → Master) :
  Agent VPS ──push HTTP POST──→ mesh ──→ Pi:3002 /push
  Agent Pi  ──push HTTP POST──→ localhost:3002 /push
  Intervalles adaptatifs : hot / warm / cold

COMMANDES (Master → Agent, via WS initié par l'Agent) :
  Agent VPS ──ouvre WS──→ mesh ──→ Pi:3002 /ws
  Agent Pi  ──ouvre WS──→ localhost:3002 /ws
  Auth : machine_id + token HMAC
  Commandes : collect, restart_module, update_config, ping
  Reconnexion auto (retry 5s)

DASHBOARD (navigateur → Master) :
  Admin ──NetBird──→ Pi Traefik Internal → bientot.domain.fr
  API REST + SSE temps réel
  Commandes dashboard → Master → WS → Agent

Sécurité :
  - Agent n'expose AUCUN port (initie toutes les connexions)
  - Master : dashboard via Traefik Internal, agent API :3002 direct mesh
  - Vérifier que update_config ne permet PAS de changer ServerURL via WS
```

---

## Alerting — responsabilités

```
NTFY = un tuyau. L'infra le déploie. C'est tout.
ZÉRO DOUBLON : chaque alerte a UN SEUL responsable.

Bientôt Master (Pi) :
  Container crash / restart         → Ntfy
  Nœud déconnecté du mesh           → Ntfy
  CPU/RAM spike anormal             → Ntfy
  Dernière backup > 24h             → Ntfy
  Espace disque < 10%               → Ntfy
  Certificat TLS expire bientôt     → Ntfy
  CVE critique (données veille-sécu) → Ntfy

CrowdSec (VPS) :
  DDoS / DoS détecté               → Ntfy
  Ban unitaire                     → PAS de notif (bruit)

Backup cron (Pi) :
  Backup échoué                    → Ntfy (seul curl "infra")

Bientôt Agent VPS — détection Pi down :
  WS Master coupé × 5 (25s)        → curl Ntfy local directement
  (Master ne peut pas alerter sa propre mort)

TODO BIENTÔT :
  1. Agent : alerte Ntfy directe si Master injoignable 5 retries
  2. Master : intégrer veille-sécu dans module CTI (/api/vulns)
```
