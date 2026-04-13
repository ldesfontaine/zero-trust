# Projet Infrastructure Zero Trust v2 — Architecture Complète

## Contexte et matériel

### Ce qu'on a

| Élément | Détail |
|---------|--------|
| **VPS Hostinger** | 1 IP publique, 100 Go stockage, Debian/Ubuntu |
| **Raspberry Pi 5** | 16 Go RAM, hat NVMe avec 2 SSD 1 To (ZFS mirror), batterie UPS Sunflower |
| **Switch** | NETGEAR MS305E — 5 ports 1G/2.5G, manageable (VLANs 802.1Q basiques) |
| **Box** | Livebox 6 Orange, 2 Gbps, pas de gestion VLAN |
| **Réseau local** | 1 port box→switch, 2 PC, 1 laptop, 1 Pi sur le switch |
| **SSD USB** | disponible pour backup local |

### Ce qu'on ne change pas

- Le matériel physique reste identique
- Budget minimal — on utilise ce qu'on a, on n'achète rien de nouveau

### Principes d'outillage

- **Terraform** : gestion du lifecycle VPS (création, destruction, clé SSH). Provider-agnostic — si on change de fournisseur cloud (Hostinger → OVH → AWS), on change le provider Terraform, pas l'Ansible
- **Ansible** : configuration de toutes les machines (cloud et bare metal). Terraform crée la VM, Ansible la configure
- **Pas de Terraform pour le bare metal** (Pi, mini PC) : Terraform gère le lifecycle de ressources cloud. Un Pi existe physiquement, on le flashe et on SSH dessus — c'est le job d'Ansible, pas de Terraform

---

## Architecture réseau cible

```
Internet
   │
   ▼
VPS — Sentinelle (DMZ)
├── Traefik         → reverse proxy HTTPS + Let's Encrypt
├── CrowdSec        → IDS/IPS (bouncer nftables — voir note firewall)
├── NetBird Server  → orchestrateur mesh WireGuard
├── Ntfy            → serveur de notifications push
├── BentoPDF        → outil PDF (public, stateless)
└── node-exporter   → métriques système

      ║ Tunnel WireGuard chiffré (NetBird mesh)
      ▼

Raspberry Pi 5 — Brain (LAN isolé via VLAN)
├── Seafile         → fichiers, sync
├── Vaultwarden     → mots de passe
├── Immich          → photos/vidéos (~250 Go)
├── AdGuard Home    → DNS mesh + blocage pub
├── Portfolio       → site perso (public via Traefik tunnel) — git clone ldesfontaine/termfolio
├── Veille Sécu     → monitoring CVE/advisories (projet séparé, déployé via Docker)
├── node-exporter   → expose métriques système (scrappé par Bientôt)
└── Bientôt         → panel admin privé : monitoring + alerting (NetBird UNIQUEMENT)
```

### Pourquoi cette répartition

```
Règle : le VPS héberge ce qui est public ou stateless.
        Le Pi héberge ce qui est privé ou touche à tes données.

VPS (public, pas de données sensibles) :
  BentoPDF   → stateless, pas de données persistantes
  → Réponse directe du VPS, pas de latence tunnel

Pi (privé + données) :
  Seafile, Vaultwarden, Immich → tes données, jamais exposées directement
  Bientôt → panel admin privé, accès NetBird UNIQUEMENT (pas public)
  Portfolio → site perso, public via Traefik tunnel VPS → Pi
  → Services privés : accès uniquement via NetBird (mesh chiffré)
  → Portfolio : public via tunnel (visiteurs passent par le VPS)
```

### Latence — qui subit quoi

```
Services publics (BentoPDF) :
  Visiteur → VPS → réponse directe
  Latence : ~10-30 ms
  ✅ Rapide, pas de tunnel

Portfolio (public via tunnel) :
  Visiteur → VPS Traefik → tunnel NetBird → Pi → Portfolio
  Latence : ~30-70 ms (tunnel aller-retour)
  ⚠️ Plus lent qu'un service sur le VPS, mais acceptable pour un site perso

Services privés (Seafile, Vaultwarden, Immich, Bientôt...) :
  Toi (NetBird) → tunnel P2P WireGuard → Pi directement
  Latence : ~5-20 ms
  ✅ Rapide, P2P direct

Futurs serveurs de jeux (NetBird P2P) :
  Joueur (NetBird) → tunnel P2P WireGuard → serveur de jeux directement
  Latence France   : ~20-50 ms (P2P direct)
  Latence Europe   : ~40-80 ms (P2P direct)
  ✅ Le VPS ne relaye PAS le trafic de jeu
  ⚠️ Fallback TURN (si P2P impossible, NAT strict des deux côtés) :
     Joueur → VPS relais → serveur = latence doublée, mais rare
     Avec une Livebox 6, le NAT est traversable, donc P2P devrait fonctionner
```

### Réseau local — VLANs sur le switch Netgear MS305E

```
Port 1 → Box Livebox 6 (untagged, VLAN par défaut)
Port 2 → Pi 5 (VLAN 10 — serveurs, isolé des PC)
Port 3 → PC 1 (VLAN 20 — clients)
Port 4 → PC 2 (VLAN 20 — clients)
Port 5 → Laptop (VLAN 20 — clients)
```

**Conséquence** : les PC ne voient plus le Pi en direct sur le LAN. Tous les accès aux services du Pi passent par le mesh NetBird. La Livebox ne gère pas le routage inter-VLAN, et c'est exactement ce qu'on veut — pas de communication directe possible entre VLAN 10 et VLAN 20 hors du tunnel chiffré.

**Configuration** : manuelle via l'interface web Netgear, documentée dans un fichier markdown dans le repo. Pas d'automatisation — c'est du one-shot.

---

## Workflow de déploiement

### Le bootstrap paradox — assumé et documenté

Le déploiement initial nécessite un accès local. C'est inévitable (même les pros ont ce problème — ils le déplacent juste avec du cloud-init ou du PXE, mais le seed manuel existe toujours quelque part).

### Les trois modes de déploiement

```
┌─────────────────────────────────────────────────────────────┐
│ RUN 0 — Bootstrap (depuis ton PC local, 1 seule fois)      │
│                                                             │
│  Objectif : rendre les machines accessibles via le mesh.    │
│  C'est TOUT. Aucun service, aucune stack, aucun backup.     │
│  Une fois le mesh UP, la CI/CD fait le reste.               │
│                                                             │
│  === VPS (via Terraform) ===                                │
│  1. terraform apply                                         │
│     → Crée le VPS Hostinger via l'API                       │
│     → Injecte la clé SSH automatiquement                    │
│     → Output : IP publique du VPS                           │
│     Si demain tu changes de provider (OVH, AWS...),         │
│     tu changes le .tf, pas le reste.                        │
│                                                             │
│  === Pi / bare metal (Ansible, SSH password) ===            │
│  2. ansible-playbook playbooks/bootstrap.yml --limit brain  │
│     → Crée user, injecte clé SSH sur le Pi                  │
│                                                             │
│  === Toutes les machines (Ansible) ===                      │
│  3. ansible-playbook playbooks/infrastructure.yml           │
│     → Layers 1-2 : système, hardening, Docker              │
│     → Layer 3 PARTIEL : installe NetBird client seulement   │
│       (pas d'ACLs, pas de DNS — les IPs sont pas connues)   │
│                                                             │
│  4. Enrollment NetBird manuel                               │
│     → Setup key dans le dashboard                           │
│     → Enrôler VPS + Pi + ton device admin                   │
│                                                             │
│  5. Récupérer les IPs NetBird attribuées                    │
│     → Les rentrer dans GitHub Secrets :                     │
│       NETBIRD_VPS_IP, NETBIRD_PI_IP,                        │
│       ANSIBLE_VAULT_PASSWORD, SSH_PRIVATE_KEY                │
│                                                             │
│  C'est fini. On ne touche plus le PC local pour déployer.   │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ RUN 1 — Premier workflow_dispatch (GitHub Actions)          │
│                                                             │
│  Trigger : bouton dans GitHub UI, juste après le Run 0      │
│  Le VPS est le bastion — il a accès au Pi via NetBird       │
│                                                             │
│  1. infrastructure.yml (avec les vraies IPs NetBird)        │
│     → Layer 3 COMPLET : ACLs, groupes, DNS AdGuard,        │
│       rewrites, suppression policy Default                  │
│     → Mesh Zero Trust pleinement opérationnel               │
│                                                             │
│  2. services.yml                                            │
│     → Layer 4 : toute la stack applicative                  │
│     → Traefik, CrowdSec, Seafile, Vaultwarden,           │
│       Immich, monitoring, veille sécu, etc.                 │
│                                                             │
│  3. operations.yml                                          │
│     → Layer 5 : backup ZFS, alerting Ntfy                   │
│                                                             │
│  Résultat : infra complète, tout tourne.                    │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ CI — Automatique sur chaque push (GitHub Actions cloud)     │
│                                                             │
│  Trigger : push sur main ou PR                              │
│  Runner : GitHub-hosted (pas besoin d'accès SSH)            │
│                                                             │
│  1. ansible-lint → vérifie syntaxe et bonnes pratiques      │
│  2. ansible-playbook --check → dry-run (simule)             │
│  3. Rapport : OK / erreurs détectées                        │
│                                                             │
│  Aucun déploiement. Juste de la validation.                 │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ CD — Deploy manuel via GitHub Actions (workflow_dispatch)   │
│                                                             │
│  Trigger : bouton "Run workflow" dans GitHub UI             │
│  Runner : GitHub-hosted                                     │
│  Accès : SSH vers VPS (IP publique + clé dans GH Secrets)  │
│          VPS relaye vers Pi via NetBird (bastion)           │
│                                                             │
│  Paramètres au lancement :                                  │
│  ┌──────────────────────────────────────────────┐           │
│  │ Playbook : [infrastructure|services|operations]          │
│  │ Tags     : (vide = tout, ou "seafile", "backup"...)    │
│  │ Limit    : (vide = tout, ou "vps", "brain-01"...)        │
│  │ Mode     : [check|apply]                                 │
│  └──────────────────────────────────────────────┘           │
│                                                             │
│  Flow d'exécution :                                         │
│  GitHub Runner → SSH VPS → ansible-playbook (sur VPS)       │
│                         → VPS SSH Pi via NetBird si --limit │
│                           inclut des machines LAN           │
│                                                             │
│  Le VPS est le bastion de déploiement.                      │
│  Ansible est installé sur le VPS pour cette raison.         │
│  Le repo est cloné sur le VPS par le workflow.              │
└─────────────────────────────────────────────────────────────┘
```

### Résumé : qui déploie quoi et quand

| Scénario | Méthode | Depuis où |
|----------|---------|-----------|
| VPS from scratch | Terraform apply | Ton PC local |
| Pi/bare metal from scratch | Ansible bootstrap (SSH password) | Ton PC local |
| Monter le mesh (layers 1-3 partiels) | Ansible infrastructure.yml + enrollment NetBird | Ton PC local |
| Premier déploiement complet | workflow_dispatch (infra + services + ops) | GitHub UI |
| Fix une config, update un service | workflow_dispatch | GitHub UI (n'importe quel device) |
| Ajouter un nouveau VPS | Terraform apply + bootstrap + enrollment + GH dispatch | PC local puis GitHub |
| Ajouter un bare metal (Pi, mini PC) | Ansible bootstrap + enrollment + GH dispatch | PC local puis GitHub |
| Disaster recovery totale | Terraform + Run 0 + enrollment + GH dispatch | Ton PC local |
| Changer de provider cloud | Modifier le .tf, terraform apply | Ton PC local |
| Push un changement Ansible | CI automatique (lint + check) | Automatique sur push |

---

## Système de layers — ordre d'exécution

Chaque layer ne dépend que du précédent. **Jamais de retour en arrière.** Un layer posé ne sera pas remodifié par un layer suivant.

```
Layer 0 — Bootstrap
  └── Créer DEUX users :
      1. User admin (lucas) → ton compte, sudo complet
      2. User deploy → compte dédié CI/CD, droits LIMITÉS :
         - Peut : docker compose up/down, git pull, lire les configs
         - Ne peut PAS : modifier UFW, modifier SSH, sudo complet
         - Clé SSH dédiée (différente de ta clé admin)
         - Si la clé est compromise (leak GitHub), l'attaquant peut
           redéployer des services mais ne peut PAS casser l'infra
      Ce layer n'existe que pour le Run 0.

Layer 1 — OS
  ├── apt upgrade, timezone, locale, paquets de base
  ├── Firewall (nftables) :
  │   → Règles posées UNE SEULE FOIS, plus modifiées après
  │   → ⚠️ CrowdSec bouncer utilise nftables directement
  │   → UFW est un wrapper iptables → CONFLIT possible avec nftables
  │   → DÉCISION : utiliser nftables natif (pas UFW) sur le VPS
  │     CrowdSec bouncer injecte ses règles dans nftables
  │     Nos règles de base aussi → un seul backend, zéro conflit
  │   → Sur le Pi : UFW suffit (pas de CrowdSec sur le Pi)
  ├── SSH hardening (port custom, algos modernes, clé only, root désactivé)
  │   → Configuré UNE SEULE FOIS, plus jamais touché après
  └── unattended-upgrades (mises à jour sécu automatiques)

Layer 2 — Runtime
  ├── Docker engine (multi-arch : amd64 + arm64)
  └── ZFS configuration (conditionnel : seulement si hardware_type le requiert)

Layer 3 — Réseau mesh
  ├── NetBird client (install + enrollment)
  ├── NetBird ACLs (groupes + policies zero trust)
  └── AdGuard DNS (resolver mesh + rewrites services privés)

Layer 4 — Services applicatifs
  ├── Chaque service = un rôle indépendant
  ├── Déployé uniquement si déclaré dans l'inventaire de la machine
  └── Monitoring (node-exporter) sur chaque machine
      Projets externes (veille sécu, bientôt) déployés comme containers Docker
      par le rôle Ansible correspondant (git clone + docker compose up)

Layer 5 — Opérations
  ├── Backup ZFS (snapshots + exports)
  ├── Alerting Ntfy (notifications)
  └── Veille sécu (monitoring CVE)
```

### Pourquoi cet ordre est important

Le problème de l'Ansible actuel : le `stack_pi.yml` bind les ports Docker sur l'IP NetBird, mais cette IP n'existe qu'après l'enrollment NetBird (Layer 3). Donc au Run 1, les ports sont bindés sur une IP placeholder, et il faut relancer pour corriger. C'est ce qui crée la confusion Run 1 / Run 2.

**Solution** : le Layer 4 (services) a une dépendance explicite sur le Layer 3 (réseau mesh). Si l'IP NetBird n'est pas encore connue, le Layer 4 attend ou échoue proprement avec un message clair. Pas de placeholder, pas de "relancer plus tard".

---

## Structure du repo

```
infra/
│
├── ansible.cfg
│
├── terraform/                       → Lifecycle des VPS cloud
│   ├── main.tf                      → provider Hostinger + ressource VPS
│   ├── variables.tf                 → IP, région, plan, clé SSH
│   ├── outputs.tf                   → IP publique créée → utilisée par Ansible
│   ├── terraform.tfvars             → valeurs (gitignored si secrets)
│   └── providers/                   → configs alternatives (OVH, AWS) prêtes à swap
│
├── inventory/
│   ├── hosts.yml                    → toutes les machines et leurs rôles
│   └── group_vars/
│       ├── all.yml                  → versions images, domaine, config commune (pas de secrets)
│       ├── sentinels.yml            → config spécifique machines DMZ
│       └── brains.yml               → config spécifique machines LAN
│
├── host_vars/
│   ├── vps.yml                      → secrets VPS (vault encrypted)
│   └── brain-01.yml                 → secrets Pi (vault encrypted)
│
├── playbooks/
│   ├── bootstrap.yml                → Layer 0 uniquement
│   ├── infrastructure.yml           → Layers 1-3
│   ├── services.yml                 → Layer 4
│   ├── operations.yml               → Layer 5
│   └── onboard.yml                  → Layers 0-3 pour nouvelle machine
│
├── roles/
│   │
│   │── # Layer 1 — OS
│   ├── base/                        → apt, users, locale, timezone
│   ├── firewall/                    → UFW, règles définitives
│   ├── hardening/                   → SSH (port, algos, clé only)
│   │
│   │── # Layer 2 — Runtime
│   ├── docker/                      → Docker engine (amd64 + arm64)
│   ├── zfs/                         → ZFS config (conditionnel hardware)
│   │
│   │── # Layer 3 — Réseau
│   ├── netbird-client/              → install + enrollment
│   ├── netbird-acl/                 → groupes + policies
│   ├── adguard-dns/                 → DNS rewrites
│   │
│   │── # Layer 4 — Services
│   ├── traefik/                     → reverse proxy (sentinel only)
│   ├── crowdsec/                    → IDS/IPS (sentinel only)
│   ├── netbird-server/              → serveur NetBird (sentinel only)
│   ├── ntfy/                        → notifications push (sentinel only)
│   ├── bentopdf/                    → outil PDF (sentinel, public, stateless)
│   ├── portfolio/                   → site perso (brain, public via tunnel) — git clone ldesfontaine/termfolio
│   ├── seafile/                     → cloud fichiers (brain only)
│   ├── vaultwarden/                 → gestionnaire mots de passe (brain only)
│   ├── immich/                      → photos/vidéos (brain only)
│   ├── adguard/                     → DNS + blocage pub (brain only)
│   ├── monitoring/                  → node-exporter (expose métriques)
│   ├── veille-secu/                 → git clone + docker compose (projet externe)
│   └── bientot/                     → git clone + docker compose (projet externe)
│   │
│   │── # Layer 5 — Opérations
│   ├── backup-zfs/                  → snapshots + exports chiffrés
│   └── alerting/                    → Bientôt alerting → Ntfy
│   │
│   │── # Hardware (conditionnel)
│   └── hardware/
│       └── pi5-nvme/                → hat NVMe, UPS Sunflower, config ARM64
│
├── .github/
│   └── workflows/
│       ├── ci.yml                   → lint + dry-run sur chaque push
│       └── deploy.yml               → workflow_dispatch (deploy manuel)
│
└── docs/
    ├── ARCHITECTURE.md              → ce document
    ├── BOOTSTRAP.md                 → procédure Run 0 pas à pas
    ├── ADDING-MACHINE.md            → comment onboard une nouvelle machine
    ├── DISASTER-RECOVERY.md         → tout est mort, comment reconstruire
    ├── SWITCH-VLAN.md               → config VLAN Netgear MS305E
    └── SECRETS.md                   → gestion des secrets (vault + GitHub)
```

---

## Inventaire — modularité machine

```yaml
# inventory/hosts.yml
all:
  children:

    sentinels:
      hosts:
        vps:
          ansible_host: XX.XX.XX.XX
          ansible_port: 2222
          machine_role: sentinel
          hardware_type: vps-generic
          services:
            - traefik
            - crowdsec
            - netbird-server
            - ntfy
            - bentopdf

    brains:
      hosts:
        brain-01:
          ansible_host: 192.168.1.XX
          ansible_port: 2223
          machine_role: brain
          hardware_type: pi5-nvme      # ← active le rôle hardware/pi5-nvme
          services:
            - seafile
            - vaultwarden
            - immich
            - adguard
            - node-exporter
            - portfolio         # git clone + docker build
            - veille-secu       # projet externe, déployé via git clone + docker compose
            - bientot           # projet externe, panel admin privé
```

### Ajouter une nouvelle machine demain

```yaml
        brain-02:
          ansible_host: 192.168.1.YY
          ansible_port: 2223
          machine_role: brain
          hardware_type: generic-x86    # ← pas de rôle hardware spécifique
          services:
            - jellyfin
            - monitoring
```

Puis :

```bash
# Depuis ton PC (Run 0 pour la nouvelle machine)
ansible-playbook playbooks/onboard.yml --limit brain-02

# Enrollment NetBird manuel

# Depuis GitHub Actions (deploy services)
# workflow_dispatch → playbook: services, limit: brain-02
```

Les ACLs NetBird se mettent à jour automatiquement : le rôle `netbird-acl` lit l'inventaire et crée les groupes/policies pour toutes les machines déclarées.

---

## Système de tags

### Tags par layer et par role

Chaque role porte le tag de son layer + son propre tag.

| Layer | Tags de roles |
|-------|---------------|
| L1-L2 | `system-vps`, `hardening-vps`, `system-pi`, `hardening-pi`, `docker` |
| L3 | `traefik`, `netbird-server`, `netbird-client` |
| L4 | `stack-vps`, `stack-pi`, `crowdsec-bouncer`, `netbird-dns`, `adguard-dns`, `netbird-acl`, `veille-secu`, `bientot` |
| L5 | `backup-zfs`, `image-maintenance`, `alerting` |

### Tags par service (L4)

Les roles `stack-vps` et `stack-pi` supportent des tags par service pour un deploiement cible sans toucher aux autres containers.

| Tag | Services Docker cibles | Machine |
|-----|----------------------|---------|
| `crowdsec` | crowdsec + bouncer nftables | VPS |
| `ntfy` | ntfy | VPS |
| `node-exporter-vps` | node-exporter | VPS |
| `seafile` | seafile, seafile-db, memcached | Pi |
| `vaultwarden` | vaultwarden | Pi |
| `immich` | immich-server, immich-db, immich-redis | Pi |
| `adguard` | adguard, adguard-exporter | Pi |
| `bentopdf` | bentopdf | Pi |
| `portfolio` | portfolio | Pi |
| `node-exporter-pi` | node-exporter | Pi |

```bash
# Toute la stack Pi
ansible-playbook playbooks/services.yml --tags stack-pi --limit pi_serv

# Un seul service
ansible-playbook playbooks/services.yml --tags seafile --limit pi_serv
ansible-playbook playbooks/services.yml --tags crowdsec --limit vps_serv

# Dry-run complet
ansible-playbook playbooks/services.yml --check --diff

# Layer reseau sur le VPS
ansible-playbook playbooks/infrastructure.yml --tags layer3 --limit vps_serv
```

### Dependances entre roles

Les dependances sont gerees par l'ordre des playbooks (`infrastructure.yml` avant `services.yml`), pas par `meta/main.yml`. Cela evite la double execution des roles partages comme `docker`.

---

## Backup ZFS — stratégie 3-2-1

### Les 3 copies

```
Copie 1 — ZFS mirror (Pi)
  └── 2 NVMe en mirror, protection hardware
      Pas un backup : si rm -rf, les deux disques répliquent la destruction

Copie 2 — SSD USB (local, support différent, AIR-GAPPED, CHIFFRÉ LUKS)
  └── DÉCONNECTÉ en temps normal. Branché uniquement pour backup.
      Chiffré avec LUKS — passphrase mémorisée (le seul secret dans ta tête)
      Survit à : ransomware, surtension, compromission Pi, rm -rf
      Résiste au vol / cambriolage (chiffrement disque complet)
      C'est ta dernière ligne de défense.
      Backup complet de toutes les données (y compris médias Immich)
      Contient aussi : la clé GPG privée pour déchiffrer les backups VPS

Copie 3 — VPS chiffré GPG (off-site, 100 Go disponibles)
  └── Chiffrement asymétrique GPG (clé publique sur le Pi, clé privée ABSENTE du Pi)
      Données CRITIQUES uniquement — déclarées par chaque rôle (modulaire)
      Le VPS n'a PAS la clé de déchiffrement
      → même compromis, l'attaquant n'a qu'un blob opaque
```

### Architecture de chiffrement — la chaîne de confiance

```
Ta tête
  └── Passphrase LUKS (le seul secret à mémoriser)
        └── Déverrouille le SSD USB
              └── Contient la clé GPG privée
                    └── Déchiffre les backups VPS

Ce qui est où :
  Pi         → clé GPG PUBLIQUE uniquement (peut chiffrer, pas déchiffrer)
  VPS        → 100 Go, blobs chiffrés GPG (ne peut rien lire)
  SSD USB    → chiffré LUKS, contient tout + clé GPG privée
  Vaultwarden → copie de la clé GPG privée (accès quotidien pratique)
  Ta tête    → passphrase LUKS

Scénarios de compromission :
  Pi compromis     → attaquant a la clé publique GPG = inutile
  VPS compromis    → blobs GPG chiffrés = inutile sans la clé privée
  SSD volé         → chiffré LUKS, rien sans la passphrase
  Tout mort        → SSD + passphrase = tu restaures tout
```

### Backup VPS — système modulaire

Chaque rôle Ansible qui a des données persistantes déclare un `backup.yml` :

```yaml
# roles/vaultwarden/backup.yml
backup_vps:
  enabled: true
  priority: critical
  paths:
    - "{{ stack_dir }}/vaultwarden/data"
  pre_hook: ~
  estimated_size: "50M"

# roles/seafile/backup.yml
backup_vps:
  enabled: true
  priority: critical
  paths:
    - "{{ stack_dir }}/seafile/config"
    - "{{ stack_dir }}/seafile/data"     # si < seuil configurable
  pre_hook: "docker exec seafile-db mysqldump --all-databases"
  pre_hook_output: /tmp/seafile-db.sql
  estimated_size: "variable"

# roles/veille-secu/backup.yml
backup_vps:
  enabled: true
  priority: normal
  paths:
    - "{{ stack_dir }}/veille-secu/data/veille.db"
  estimated_size: "10M"

# roles/immich/backup.yml
backup_vps:
  enabled: false           # trop gros, SSD USB uniquement

# roles/bientot/backup.yml
backup_vps:
  enabled: false           # métriques recréables, pas de backup
```

**Ajouter un service = ajouter un `backup.yml` dans le rôle. Le cron de backup le détecte automatiquement.**

### Statut de backup — exposé pour Bientôt

Chaque opération de backup écrit un fichier de statut JSON :

```json
// /mnt/tank/stack/backup/status/vps-latest.json
{
  "type": "vps",
  "timestamp": "2026-04-07T03:00:00Z",
  "success": true,
  "size_bytes": 134217728,
  "services_backed_up": ["vaultwarden", "seafile", "veille-secu"],
  "checksum": "sha256:abc123...",
  "vps_disk_remaining_gb": 87
}

// /mnt/tank/stack/backup/status/usb-latest.json
{
  "type": "usb",
  "timestamp": "2026-03-15T14:30:00Z",
  "success": true,
  "size_bytes": 912345678,
  "snapshot_name": "tank@backup-usb-20260315-143000",
  "checksum": "sha256:def456...",
  "days_since_last": 23
}
```

**Bientôt scrape ces fichiers** et affiche dans le dashboard :
- Dernier backup VPS : date, taille, statut, espace restant
- Dernier backup USB : date, nombre de jours depuis, alerte si > 30j
- Checksum OK/KO pour chaque backup
- Historique des backups (tableau simple)
```

### Snapshots ZFS automatiques (cron sur le Pi)

```
Toutes les heures : conservation 24h
Quotidien         : conservation 7 jours
Hebdomadaire      : conservation 4 semaines
Mensuel           : conservation 6 mois
```

Ces snapshots sont la première ligne de défense contre les erreurs humaines (rm -rf, mauvaise manip). Tu peux restaurer un fichier supprimé il y a 3 heures sans toucher aux backups. Ils ne protègent PAS contre une panne hardware (les deux NVMe qui claquent) — c'est le job du SSD USB et du VPS.

### Automatisation — backup VPS (quotidien, automatique)

```
Cron quotidien sur le Pi (3h du matin) :

1. Dump MariaDB Seafile
   → docker exec seafile-db mysqldump --all-databases > /tmp/seafile-db.sql
   → Dump cohérent, contrairement aux fichiers bruts de MariaDB

2. Snapshot ZFS temporaire
   → zfs snapshot tank@backup-vps-daily
   → Atomique, fige l'état du pool

3. Collecter les données critiques depuis le snapshot
   → tar : vaultwarden/data + seafile/config + seafile/data (si < seuil)
     + dump SQL + veille-secu/db + terraform state

4. Chiffrer avec GPG asymétrique
   → gpg --encrypt --recipient backup@ton-domaine
   → Le Pi a SEULEMENT la clé publique → il peut chiffrer mais PAS déchiffrer
   → Compromission du Pi = l'attaquant ne peut pas lire les backups existants

5. Envoyer au VPS via NetBird
   → scp ou rsync via le tunnel chiffré
   → Répertoire VPS : /opt/backups/brain-01/
   → Rotation : garder 7 jours, supprimer les plus vieux

6. Nettoyage
   → Supprimer le dump SQL temporaire
   → Supprimer le snapshot ZFS temporaire
   → zfs destroy tank@backup-vps-daily

7. Vérification + notification
   → Vérifier que le fichier est arrivé (checksum)
   → Vérifier l'espace disque restant sur le VPS
   → Ntfy : "Backup VPS OK — 127 Mo chiffré envoyé, 12 Go restants"
   → Ou Ntfy : "❌ Backup VPS échoué — raison : ..."
```

### Backup SSD USB — procédure automatique avec déverrouillage LUKS

Tu branches, tu tapes ta passphrase, le reste est automatique.

```
Étape 1 — Tu branches le SSD USB sur le Pi
  │
  ▼
Étape 2 — udev rule détecte le disque (par UUID de la partition LUKS)
  │  → Ntfy : "🔌 SSD détecté — en attente de déverrouillage"
  │  → Le script attend le déverrouillage LUKS
  │  → Deux options pour taper la passphrase :
  │    A) SSH sur le Pi : cryptsetup luksOpen /dev/sdX backup
  │    B) Mini page web locale (sur le Pi, accessible via NetBird)
  │       → champ "passphrase" → tu tapes depuis ton téléphone
  │       → la page appelle cryptsetup en backend
  │       → HTTPS via certificat local, la passphrase ne transite
  │         jamais en clair sur le réseau
  │
  ▼
Étape 3 — SSD déverrouillé → monté sur /mnt/backup-usb
  │  → Ntfy : "🔓 SSD déverrouillé — backup lancé"
  │
  ▼
Étape 4 — zfs snapshot tank@backup-usb-YYYYMMDD-HHMMSS
  │  → ATOMIQUE : prend ~1 seconde, fige l'état du pool
  │  → Les uploads Seafile/Immich en cours continuent
  │    sur le pool live, le snapshot est cohérent
  │  → Aucun fichier corrompu, aucun conflit possible
  │
  ▼
Étape 5 — zfs send (incrémental si snapshot précédent existe sur le SSD)
  │  → Premier backup : envoi complet (~850 Go, peut prendre des heures)
  │  → Backups suivants : envoi incrémental (seulement les deltas, rapide)
  │  → Ntfy progress optionnel : "Backup en cours — 45% (382 Go / 847 Go)"
  │
  ▼
Étape 6 — Vérification intégrité
  │  → Checksum du snapshot envoyé vs snapshot source
  │  → Si échec : Ntfy "❌ Backup corrompu, ne pas débrancher, relance en cours"
  │
  ▼
Étape 7 — Nettoyage
  │  → Supprime les anciens snapshots de backup sur le SSD (garde les 3 derniers)
  │  → Supprime le snapshot temporaire sur le pool source
  │  → Log la date du backup dans /mnt/tank/stack/backup/last-usb-backup.txt
  │
  ▼
Étape 8 — Fermeture chiffrée + éjection propre
  │  → sync && umount /mnt/backup-usb
  │  → cryptsetup luksClose backup
  │  → udisksctl power-off du disque USB
  │  → Ntfy : "✅ Backup terminé — 847 Go, intégrité OK, SSD chiffré fermé
  │            et éjecté. Tu peux débrancher en toute sécurité."
  │
  ▼
Tu débranches le SSD. Tu le ranges (idéalement pas dans la même pièce que le Pi).

Monitoring :
  → Le fichier last-usb-backup.txt est vérifié par le monitoring
  → Si pas de backup USB depuis > 30 jours :
    Ntfy : "⚠️ Pas de backup USB depuis 32 jours. Branche ton SSD."
```

**Pourquoi c'est safe même avec des uploads en cours :**
Le `zfs snapshot` est une opération atomique au niveau du filesystem.
Il capture l'état EXACT du pool à l'instant T. Les écritures en cours
(upload Seafile, import Immich) ne sont pas dans le snapshot — elles
atterrissent sur le pool live. Le snapshot est toujours cohérent, comme
si tu avais appuyé sur "pause" pendant 1 milliseconde.

**Pourquoi le SSD doit rester DÉCONNECTÉ :**
- Surtension / foudre → SSD branché = SSD mort
- Ransomware sur le Pi → tout ce qui est monté est chiffrable
- rm -rf accidentel → un SSD monté est une cible
- Vol / cambriolage → SSD chiffré LUKS, inutile sans la passphrase
- Le SSD déconnecté + chiffré est la SEULE copie qui survit au pire scénario

### Restauration — playbook dédié

Pas de restauration manuelle. Des playbooks prêts à l'emploi.

```
playbooks/
└── restore.yml

# Restaurer Vaultwarden depuis le backup VPS
ansible-playbook playbooks/restore.yml --tags vaultwarden --limit brain-01

# Restaurer Seafile depuis le SSD USB (branché + déverrouillé)
ansible-playbook playbooks/restore.yml --tags seafile --limit brain-01 \
  -e restore_source=usb

# Restaurer tout depuis le SSD USB
ansible-playbook playbooks/restore.yml --limit brain-01 -e restore_source=usb

# Restaurer tout depuis le VPS (données critiques uniquement)
ansible-playbook playbooks/restore.yml --limit brain-01 -e restore_source=vps
```

**Ce que fait restore.yml :**

```
1. Stoppe le service ciblé
   → docker compose down (pour le service concerné)

2. Récupère le backup selon la source :
   VPS → télécharge le dernier backup chiffré via NetBird
       → déchiffre avec la clé GPG privée (doit être disponible sur le Pi
         ou fournie manuellement)
   USB → vérifie que le SSD est monté et déverrouillé
       → lit le snapshot ZFS correspondant

3. Restaure les données au bon endroit :
   Vaultwarden → restore data/ dans /mnt/tank/stack/vaultwarden/
   Seafile    → mysql < dump.sql (restaure la DB)
               → restore config/ et data/
   Veille sécu → restore SQLite
   Immich      → restore depuis SSD USB uniquement

4. Relance le service
   → docker compose up -d

5. Healthcheck
   → Vérifie que le service répond (HTTP, port, etc.)

6. Notification
   → Ntfy : "✅ Restauration [service] terminée — service UP"
   → Ou Ntfy : "❌ Restauration [service] échouée — raison : ..."
```

**Disaster recovery total (Pi mort, nouveau hardware) :**

```
1. Terraform apply → VPS (si VPS aussi mort)
2. bootstrap.yml → nouveau Pi/mini PC
3. infrastructure.yml → système + mesh
4. Enrollment NetBird
5. Rentrer les IPs NetBird dans GitHub Secrets
6. GitHub workflow_dispatch → services.yml (installe les containers vides)
7. Branche le SSD USB → tape la passphrase LUKS
8. restore.yml -e restore_source=usb → restaure toutes les données
   OU (si SSD USB perdu/détruit) :
   restore.yml -e restore_source=vps → restaure les données critiques
   (il te faut la clé GPG privée — dans Vaultwarden ou sur le SSD)
9. operations.yml → réactive backup + alerting

Documenté pas à pas dans docs/DISASTER-RECOVERY.md
```

---

## Alerting — Ntfy

### Où tourne Ntfy

Sur le **VPS** (sentinel). Pourquoi pas le Pi ? Parce que si le Pi tombe, tu veux être alerté, et si Ntfy est sur le Pi, tu reçois rien.

### Alertes configurées

```
Critique (notification immédiate) :
  - Container down (docker healthcheck fail)
  - ZFS pool degraded (disque NVMe en erreur)
  - Disk > 90%
  - VPS ou Pi unreachable (health check ICMP)
  - Certificat TLS expire dans < 7 jours
  - CrowdSec ban sur une IP du mesh (auto-ban)

Warning :
  - RAM > 85%
  - CPU > 90% pendant > 5 min
  - Backup pas exécuté depuis > 48h
  - Nouvelle CVE critique sur un produit du stack

Info :
  - Deployment effectué (via CI)
  - Nouveau device connecté au mesh NetBird
  - Veille sécu : nouveau bulletin CERT-FR
```

### Pipeline technique

```
Bientôt (dashboard centralisé) → évalue les métriques (node-exporter Pi + VPS)
  → webhook Ntfy (sur le VPS)
    → push notification sur ton téléphone (app Ntfy)

Veille sécu → détecte CVE matchant ton stack
  → appel API Ntfy directement
    → push notification
```

---

## ACLs NetBird — Zero Trust réseau

### Concept

Deny-by-default. La policy Default (All → All) est **supprimée**. Chaque flux doit être explicitement autorisé par une policy. Si aucune policy ne matche, le trafic est bloqué.

### Groupes

Un groupe est un label collé à des peers (machines). Un peer peut être dans plusieurs groupes.

```
sentinels   → VPS (machines DMZ, exposées internet)
brains      → Pi brain-01 (machines données, LAN)
              Futurs mini PC iront aussi dans ce groupe
admins      → ton laptop, téléphone, devices perso
ci-runner   → VPS (double rôle : le VPS est à la fois sentinel ET ci-runner)
              Demain si tu as un runner CI dédié, tu le mets ici
              et tu retires le VPS de ce groupe
```

### Policies

```
Policy : "admins-full-sentinels"
  admins ↔ sentinels : ALL (bidirectionnel)
  → Ton laptop peut SSH sur le VPS, accéder à tous les services

Policy : "admins-full-brains"
  admins ↔ brains : ALL (bidirectionnel)
  → Ton laptop accède à tous les services du Pi

Policy : "sentinel-to-brain-web"
  sentinels → brains : TCP 8090, 8092, 8093, 3000, 3001 (unidirectionnel)
  → Traefik sur le VPS proxy vers les services du Pi
    (Portfolio 8090, Seafile 8092, Vaultwarden 8093, AdGuard 3000, Bientôt 3001)
  → BentoPDF est sur le VPS (local), pas besoin de proxy
  → Le VPS NE PEUT PAS SSH sur le Pi via cette policy

Policy : "ci-deploy"
  ci-runner → brains : TCP 2223 (unidirectionnel)
  → Le VPS (en tant que ci-runner) peut SSH sur le Pi pour déployer
  → C'est LA policy qui permet à GitHub Actions de fonctionner
  → Séparée de sentinel-to-brain-web : responsabilités distinctes

Policy : "brain-to-sentinel-monitoring"
  brains → sentinels : TCP 9100, 6060 (unidirectionnel)
  → Bientôt sur le Pi scrape les métriques du VPS (node-exporter + CrowdSec)

Policy : "infra-icmp"
  sentinels ↔ brains : ICMP (bidirectionnel)
  → Ping health checks entre les machines

Policy Default : SUPPRIMÉE
  → Tout ce qui n'est pas ci-dessus est BLOQUÉ
```

### Ajouter un serveur de jeux dans le futur — exemple concret (PAS à implémenter maintenant)

**À prévoir pour dans quelques mois.** L'architecture est pensée pour, mais on ne code rien pour ça en Phase 1-4. C'est un exemple pour montrer comment les ACLs scalent.

Tu achètes un mini PC, tu veux héberger un serveur Minecraft et Terraria pour tes potes. Voilà exactement ce que tu fais :

```
Nouvelle machine : game-server-01
  → Groupe : "gameservers"

Tes potes installent NetBird sur leur PC :
  → Groupe : "gamers"

Nouvelles policies :
  "gamers-to-gameservers"
    gamers → gameservers : TCP 25565 (Minecraft), TCP 7777 (Terraria)
    → Tes potes accèdent aux jeux, rien d'autre

  "admins-to-gameservers"
    admins ↔ gameservers : ALL
    → Toi tu gères tout (SSH, monitoring, etc.)

CE QUI N'EXISTE PAS (et c'est le point crucial) :
  ❌ Pas de policy gamers → brains
     → Tes potes ne voient PAS ton Seafile, Vaultwarden, Immich
  ❌ Pas de policy gamers → sentinels
     → Tes potes ne voient PAS ton VPS
  ❌ Pas de policy gameservers → brains
     → Même si le serveur de jeux est compromis,
       il ne peut PAS atteindre tes données personnelles

Résultat : compromission du serveur de jeux = ZÉRO impact sur ton infra perso.
Chaque machine ne voit que ce qu'elle a le droit de voir.
```

### Gestion automatique via Ansible

Le rôle `netbird-acl` lit l'inventaire et génère les groupes + policies automatiquement. Ajouter une machine dans l'inventaire avec le bon `machine_role` suffit — les ACLs se mettent à jour au prochain deploy.

```yaml
# inventory/hosts.yml — ajouter une machine
game-server-01:
  ansible_host: 192.168.1.ZZ
  machine_role: gameserver       # ← le rôle netbird-acl crée le groupe
  services: [minecraft, terraria]

# Le rôle netbird-acl fait automatiquement :
# 1. Crée le groupe "gameservers" si absent
# 2. Ajoute game-server-01 au groupe
# 3. Crée les policies définies pour ce type de machine
# 4. Ne touche pas aux policies existantes des autres groupes
```

---

## Veille sécu v2 — version utile

### Principes vs le repo actuel

Le repo actuel (Vielle-Cyber) est over-engineered : Redis, 40+ sources, circuit breakers, enrichissement croisé EPSS/KEV/OTX. Trop complexe, trop de sources qui cassent silencieusement, pas de notifs, pas de filtrage par ton stack.

La v2 :

```
Sources (5-6 fiables) :
  - NVD API (CVEs, gratuit)
  - CERT-FR RSS (advisories français)
  - GitHub Security Advisories API
  - CISA KEV (vulnérabilités exploitées)
  - Exploit-DB RSS

Stockage : SQLite (pas Redis)

Filtrage :
  - Par défaut : ton stack déclaré
    [traefik, seafile, vaultwarden, docker,
     linux, netbird, crowdsec, adguard, immich]
  - Custom : tu ajoutes/retires des keywords manuellement
    via un fichier de config ou une petite API
    Exemple : tu ajoutes "kubernetes", "rust", "wireguard"

Notifs :
  - CVE critique (CVSS >= 9) sur ton stack → Ntfy immédiat
  - CVE haute (CVSS >= 7) sur ton stack → Ntfy digest quotidien
  - Bulletins CERT-FR → Ntfy digest quotidien
  - Keywords custom → même logique

Interface web :
  - Dashboard simple pour consulter l'historique
  - Filtrer par produit, sévérité, date
  - Marquer comme lu/traité
  - Accessible via NetBird (service privé)

Container Docker sur le Pi (brain_private)
```

---

## Immich — médias

### Pourquoi un service dédié pour les médias

Seafile est un outil de sync de fichiers, pas un media server. Immich est conçu pour les photos/vidéos : timeline, app mobile, reconnaissance faciale, transcoding vidéo.

### Déploiement

```
- Container Docker sur le Pi
- Stockage : /mnt/tank/stack/immich/data (~250 Go)
- Réseau : brain_private (accès via NetBird uniquement)
- Backup : SSD USB uniquement (trop volumineux pour le VPS)
- Accessible via sous-domaine : photos.ton-domaine.com (privé)
```

---

## Écosystème de projets

L'infra Zero Trust est le socle. Les autres projets sont développés et versionnés **séparément** mais déployés comme containers Docker par Ansible.

```
Projet 1 — deployZeroTrustV2 (ce repo)
  │  Ansible + Terraform. Gère l'infra, déploie tout.
  │  Repo GitHub : deployZeroTrustV2
  │
  ├── Projet 2 — Veille Sécu (repo séparé)
  │     Moteur de veille cybersécurité. Python + SQLite.
  │     Repo GitHub : veille-secu
  │     Déployé sur le Pi par le rôle Ansible "veille-secu"
  │     → git clone + docker compose up
  │
  └── Projet 3 — Bientôt (repo séparé)
        Panel admin privé modulaire : monitoring + alerting. Branchable sur n'importe quelle infra.
        Remplace Grafana + VictoriaMetrics + vmagent.
        Repo GitHub : bientot
        Déployé sur le Pi par le rôle Ansible "bientot"
        → git clone + docker compose up
        Accessible UNIQUEMENT via NetBird (admin only)
        Gère : scraping métriques, stockage, alerting → Ntfy
        Expose le statut des backups (VPS + USB) dans le dashboard

Note : le portfolio (https://github.com/ldesfontaine/termfolio) est un service
à part, déployé par le rôle Ansible "portfolio" (git clone + docker build).
Ce n'est PAS un projet externe comme veille-secu/bientot — c'est un service
simple géré directement par Ansible.
```

### Comment Ansible déploie un projet externe

Chaque projet externe a son propre `docker-compose.yml` dans son repo. Le rôle Ansible correspondant fait :

```yaml
# roles/veille-secu/tasks/main.yml (même pattern pour bientot)
- name: Cloner le repo veille-secu
  git:
    repo: "https://github.com/ldesfontaine/Vielle-Technologique.git"
    dest: "{{ stack_dir }}/veille-secu"
    version: main
    force: yes

- name: Copier le fichier de config (variables Ansible → .env)
  template:
    src: veille-secu.env.j2
    dest: "{{ stack_dir }}/veille-secu/.env"

- name: Lancer le container
  shell: "cd {{ stack_dir }}/veille-secu && docker compose up -d"
```

Pour mettre à jour un projet externe : `workflow_dispatch → --tags veille-secu` → Ansible pull la dernière version du repo + restart le container.

---

## Gestion des secrets

### Deux sources, synchronisées manuellement

```
ansible-vault (pour le Run 0 local) :
  - host_vars/vps.yml (chiffré)
  - host_vars/brain-01.yml (chiffré)
  - Mot de passe maître unique

GitHub Secrets (pour la CI/CD) :
  - ANSIBLE_VAULT_PASSWORD → même mot de passe maître
  - SSH_PRIVATE_KEY → clé SSH pour accès VPS
  - Les fichiers vault encrypted sont dans le repo Git
  - Le runner GitHub les déchiffre avec le vault password

Synchronisation :
  - Quand tu changes un secret dans ansible-vault
  - Tu mets à jour le GitHub Secret correspondant si nécessaire
  - C'est le prix à payer pour ne pas dépendre d'un secret manager externe
```

### Secrets applicatifs

```
Générés au premier déploiement si absents :
  - Passwords DB (openssl rand)
  - Tokens API (openssl rand)
  - Stockés dans les fichiers vault après génération

Stockés dans Vaultwarden après setup :
  - Copie manuelle des credentials importants
  - Vaultwarden = source de vérité pour les humains
  - ansible-vault = source de vérité pour l'automatisation
```

---

## CI/CD GitHub Actions

### ci.yml — sur chaque push

```yaml
Trigger : push sur main, ou PR
Runner : GitHub-hosted (ubuntu-latest)
Pas besoin d'accès SSH

Étapes :
  1. Checkout du repo
  2. Install Ansible + ansible-lint
  3. ansible-lint → vérifie syntaxe, bonnes pratiques
  4. yamllint → vérifie les fichiers YAML
  5. ansible-playbook --syntax-check → chaque playbook
  6. Rapport dans la PR / commit status
```

### deploy.yml — workflow_dispatch manuel

```yaml
Trigger : bouton dans GitHub UI
Runner : GitHub-hosted

Paramètres (choisis au lancement) :
  - playbook : infrastructure | services | operations
  - tags : vide (tout) ou spécifique ("seafile", "backup"...)
  - limit : vide (tout) ou spécifique ("vps", "brain-01"...)
  - mode : check (dry-run) | apply (déploiement réel)

Étapes :
  1. Checkout du repo
  2. Install Ansible
  3. Configure clé SSH du user DEPLOY (depuis GitHub Secrets)
     → PAS la clé admin. Clé dédiée au user deploy (droits limités)
  4. Configure vault password (depuis GitHub Secrets)
  5. SSH vers VPS (bastion) en tant que user deploy
  6. Sur le VPS : clone/pull du repo
  7. Sur le VPS : ansible-playbook avec les paramètres choisis
     Le VPS a accès au Pi via NetBird → peut déployer les deux
     Le user deploy a les droits pour docker + git, pas pour UFW/SSH
  8. Notification Ntfy : "Deploy [playbook] terminé / échoué"
```

---

## Phases de réalisation — ordre d'attaque

### Phase 1 — Fondations (priorité absolue)

**Pourquoi en premier** : sans backup, une erreur est irrécupérable. Sans alerting, tu es aveugle. Sans refacto Ansible, tout le reste sera construit sur du sable.

```
1.1 — Refacto Ansible en rôles modulaires
  - Restructurer le repo selon la structure cible
  - Séparer en playbooks (bootstrap, infrastructure, services, operations)
  - Créer les rôles avec tags et dépendances
  - Rendre le code machine-agnostic (plus de "pi" en dur)
  - Tester le deploy complet from scratch

1.2 — Backup ZFS
  - Snapshots automatiques (zfs-auto-snapshot ou cron)
  - Export chiffré vers VPS (données critiques)
  - Script de backup vers SSD USB
  - Alerte si backup pas fait depuis X jours

1.3 — Alerting Ntfy
  - Déployer Ntfy sur le VPS
  - Configurer Bientôt alerting → webhook Ntfy
  - Alertes critiques : container down, disk full, ZFS degraded
```

### Phase 2 — Workflow de développement

**Pourquoi en deuxième** : une fois que l'infra est solide, on sécurise le processus de modification.

```
2.1 — CI GitHub Actions
  - ci.yml : lint + syntax-check sur chaque push
  - Feedback dans les PRs

2.2 — CD GitHub Actions
  - deploy.yml : workflow_dispatch avec paramètres
  - VPS comme bastion de déploiement
  - Ansible installé sur le VPS
  - Notification Ntfy post-deploy

2.3 — Documentation
  - BOOTSTRAP.md : procédure Run 0 détaillée
  - ADDING-MACHINE.md : comment onboard une nouvelle machine
  - DISASTER-RECOVERY.md : reconstruire de zéro
  - SECRETS.md : gestion des secrets
```

### Phase 3 — Nouveaux services

**Pourquoi en troisième** : l'infra est solide, le workflow est en place, on peut ajouter des services proprement.

```
3.1 — Immich
  - Container Docker sur le Pi
  - Stockage sur ZFS
  - Backup SSD USB
  - Sous-domaine privé via Traefik + NetBird

3.2 — Veille sécu v2
  - Réécriture légère : 5 sources, SQLite, Ntfy
  - Filtrage par stack auto + keywords custom
  - Dashboard web simple (privé)
  - Container Docker sur le Pi
```

### Phase 4 — Hardening réseau

**Pourquoi en dernier** : c'est de l'amélioration, pas du critique. L'infra fonctionne déjà sans les VLANs.

```
4.1 — VLAN sur le switch Netgear
  - Configuration manuelle via interface web
  - VLAN 10 : Pi (isolé)
  - VLAN 20 : PC/laptop
  - Documentation de la config

4.2 — Revue des ACLs NetBird
  - Ajuster les policies pour les nouvelles machines/services
  - Vérifier que le deny-by-default est effectif
  - Tester les accès depuis chaque type de device
```

---

## Décisions prises

1. **Ntfy** → sur le VPS. Si le Pi tombe, tu reçois les alertes.
2. **Ansible sur le VPS** → oui, le VPS est le bastion de déploiement.
3. **Veille sécu** → Python + SQLite. Simple, adapté au use case.
4. **Stockage VPS** → 100 Go confirmé. Largement suffisant pour les backups critiques.
5. **Terraform** → dans le même repo deploy, dossier `terraform/`. Pas un projet séparé.
6. **Portfolio** → reste un service séparé (git clone ldesfontaine/termfolio + docker build), déployé sur le Pi, public via Traefik tunnel.
7. **Firewall VPS** → nftables natif (pas UFW) pour éviter les conflits avec CrowdSec bouncer. UFW seulement sur le Pi.
8. **User CI/CD** → user `deploy` dédié avec droits limités (docker + git, pas UFW/SSH).
9. **Backup VPS** → système modulaire. Chaque rôle déclare ses données via `backup.yml`.

## Sous-domaines et DNS

Les sous-domaines ne sont PAS hardcodés dans le code. Ils sont déclarés dans un fichier de config :

```yaml
# group_vars/all.yml (ou fichier dédié)
domains:
  base: "ton-domaine.com"
  subdomains:
    mesh: "mesh"          # NetBird dashboard
    pdf: "pdf"            # BentoPDF
    cloud: "cloud"        # Seafile
    vault: "vault"        # Vaultwarden
    photos: "photos"      # Immich
    adguard: "adguard"    # AdGuard Home
    bientot: "bientot"    # Dashboard + site perso
    # Ajouter ici pour un nouveau service
```

Chaque sous-domaine est automatiquement :
- Routé par Traefik (cert Let's Encrypt)
- Ajouté dans les DNS rewrites AdGuard (si privé)
- Couvert par les ACLs NetBird (si privé)

Modifier un sous-domaine = modifier ce fichier + relancer `--tags traefik,adguard-dns`.

## Questions ouvertes

1. **Enrollment NetBird** — Setup keys auto-assignées à des groupes ? Réduit le manuel mais crée un risque : si une setup key fuit, quelqu'un peut enrôler un peer dans ton mesh. Mitigation : setup keys à usage unique + expiration courte. À évaluer.

2. **Terraform state** — Local dans le repo (chiffré vault) ou backend distant ? Recommandé : local chiffré pour un projet perso, pas besoin d'un backend S3.

3. **Bientôt : stack technique** — Python, Go, ou TypeScript ? À trancher avant de coder le projet.