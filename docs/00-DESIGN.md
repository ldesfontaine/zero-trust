# 00 — Architecture & Design

## Principes

| # | Principe | Implication concrète |
|---|----------|---------------------|
| 1 | Secure by design | L'architecture empêche les attaques, pas la configuration |
| 2 | DMZ jetable | Le VPS peut être reconstruit from scratch sans impact sur le privé |
| 3 | Un service = un module | Chaque service est autonome, branchable/débranchable (voir `01-SERVICES`) |
| 4 | Output policy drop | Rien ne sort sauf allowlist explicite (voir `03-FLUX`) |
| 5 | Docker socket proxy | Aucun container n'accède directement à docker.sock |
| 6 | Isolation réseau | Chaque service a son propre réseau Docker (voir `02-ISOLATION`) |
| 7 | Nœuds génériques | Pas de rôle hardcodé — un nœud = OS + Docker + NetBird + nftables |
| 8 | Mesh only entre machines | Aucune communication IP publique entre nœuds (voir `03-FLUX`) |
| 9 | Input non trusté en DMZ | Tout service traitant des données d'internet reste en DMZ |
| 10 | Code jamais sur les serveurs | Ansible tourne depuis le runner GitHub (voir `05-DEPLOY`) |
| 11 | Docker isolation stricte | Réseaux `internal: true` par défaut. Seuls traefik-edge, crowdsec, netbird sont non-internal |
| 12 | Images signées | Cosign au build, vérification au deploy (voir `05-DEPLOY`) |

---

## Zones de confiance

```
┌─────────────────────────────────────────────────────┐
│ ZONE 0 — Internet (hostile)                         │
│ Tout trafic entrant est suspect par défaut           │
└───────────────────────┬─────────────────────────────┘
                        │ HTTPS :443 + STUN :3478
                        ▼
┌─────────────────────────────────────────────────────┐
│ ZONE 1 — DMZ (exposée, jetable)                     │
│                                                     │
│ VPS : point d'entrée internet                        │
│ Services publics + reverse proxy + IDS               │
│ AUCUNE donnée privée                                 │
│ Reconstituable from scratch via Terraform + Ansible  │
└───────────────────────┬─────────────────────────────┘
                        │ Tunnel WireGuard (NetBird mesh)
                        │ IPs 100.64.x.x
                        ▼
┌─────────────────────────────────────────────────────┐
│ ZONE 2 — Réseau privé (mesh only)                   │
│                                                     │
│ Pi + futurs nœuds : services privés, données         │
│ Zéro port internet                                   │
│ Accessible uniquement via NetBird                    │
└─────────────────────────────────────────────────────┘
```

Les zones ne communiquent QUE via le mesh chiffré. Voir `03-FLUX` pour les règles détaillées.

---

## Machines

### DMZ-01 : VPS Hostinger (Debian, amd64)

Rôle : point d'entrée internet. Reverse proxy, IDS, services publics. RIEN de privé.

Composants : Traefik Edge, WAF Coraza, CrowdSec, NetBird Server, Ntfy, BentoPDF, Portfolio, Bientôt Agent, Docker Socket Proxy.

Détail des services → `01-SERVICES`

### PRIV-01 : Raspberry Pi 5 (Debian, arm64)

Rôle : services privés, données utilisateur, DNS mesh. Zéro port internet.

Composants : Traefik Internal, AdGuard Home, Seafile, Vaultwarden, Immich, Veille Sécu, Bientôt Master + Agent, Docker Socket Proxy.

Détail des services → `01-SERVICES`

### Nœud futur (générique)

Tout nouveau nœud (mini PC, VPS distant, chez un pote) reçoit la même base :

| Composant | Rôle |
|-----------|------|
| nftables (drop in + drop out) | Firewall |
| Docker + daemon.json durci | Runtime |
| NetBird Client | Connexion mesh |
| Docker Socket Proxy | Sécurité Docker |
| Bientôt Agent | Monitoring |

Services additionnels : branchables depuis la bibliothèque de modules (voir `01-SERVICES`).

---

## Séquencement des layers

```
Layer 1 — OS + nftables (policy drop IN + OUT) + SSH hardening
Layer 2 — Docker Engine + Docker Socket Proxy + daemon.json durci
Layer 3 — NetBird Client enrollment → IP mesh connue et stockée
Layer 4 — Services (bindent ports sur IP mesh — ÉCHOUE si Layer 3 pas fait)
Layer 5 — Monitoring + Backup + Alerting
```

L'IP mesh est attribuée à l'enrollment NetBird et ne change pas. Stockée comme variable Ansible. Si absente, Layer 4 refuse de se lancer.

---

## Documents liés

| Document | Contenu |
|----------|---------|
| `01-SERVICES` | Services par machine, modules, Bientôt, alerting |
| `02-ISOLATION` | Réseaux Docker, isolation, liens entre services |
| `03-FLUX` | Flux réseau, ACLs NetBird, trafic autorisé/interdit |
| `04-SECURITY` | TLS, hardening, secrets, logs, risques acceptés |
| `05-DEPLOY` | CI/CD, workflows, backup, disaster recovery |
