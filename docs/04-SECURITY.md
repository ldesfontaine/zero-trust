# 04 — Sécurité

## TLS — certificats

| Instance | Services | Méthode | Renouvellement |
|----------|----------|---------|----------------|
| Traefik Edge (VPS) | Portfolio, Ntfy, BentoPDF | Let's Encrypt challenge HTTP | Auto |
| Traefik Internal (Pi) | Seafile, Vault, Immich, Bientôt, AdGuard UI, Veille | Let's Encrypt challenge DNS | Auto |

Le challenge DNS ne nécessite PAS que le domaine soit routé publiquement. Traefik Internal gère tout automatiquement via l'API du provider DNS (Cloudflare/OVH). Token API en variable d'environnement, fichier mode 0600.

Côté Ansible : un seul rôle `traefik` paramétrable (`mode: edge` ou `mode: internal`).

---

## Hardening containers

Chaque container applique :

```yaml
security_opt:
  - no-new-privileges:true
cap_drop:
  - ALL
read_only: true           # quand possible
tmpfs:
  - /tmp                   # écriture temporaire si nécessaire
```

Les images tierces sont pinnées par version dans `versions.yml` (voir `05-DEPLOY`).

---

## Signature des images (cosign)

```
Build (GitHub Actions) :
  → docker build + push GHCR
  → cosign sign avec clé stockée dans GitHub Secrets
  → L'image est signée et le hash enregistré

Deploy (workflow 2) :
  → cosign verify avant docker compose pull
  → Si signature invalide → le deploy s'arrête
  → Protège contre : tag GHCR overwrite, compromission registry

Clé cosign :
  → Privée : GitHub Secrets uniquement
  → Publique : dans le repo Ansible (pour vérification au deploy)
```

---

## Secrets — gestion des .env

```
Contenu d'un .env :
  - Mots de passe DB (générés par Ansible : openssl rand -base64 32)
  - Tokens API (HMAC, Bearer)
  - IP mesh (100.64.x.x)
  - Ports des services
  - Domaine

Ce qui n'est PAS dans le .env :
  - La version de l'image (passée via variable d'env au deploy)

Permissions :
  - Owner : root
  - Mode : 0600
  - Le user deploy ne peut PAS les lire

Sources de vérité :
  - Automation : ansible-vault (chiffré dans Git)
  - Humain : Vaultwarden (tes mots de passe)
  - Synchronisation : manuelle
```

---

## CrowdSec

```
Emplacement : VPS uniquement (pas sur le Pi)
Sources de logs :
  1. Traefik Edge access logs (volume read-only)
  2. SSH auth.log du host (volume read-only)
  3. C'est tout — pas de logs applicatifs individuels

Alertes :
  - DDoS / DoS détecté → Ntfy
  - Ban unitaire → PAS de notif (bruit)

Le Pi n'a pas de CrowdSec :
  - Trafic mesh uniquement (trusté, chiffré WireGuard)
  - CrowdSec détecte les patterns internet, pas le trafic mesh
```

---

## Logs — rotation et rétention

```
Traefik Edge access logs (VPS) :
  logrotate quotidien, rétention 7 jours, compression gzip

Traefik Internal access logs (Pi) :
  logrotate quotidien, rétention 7 jours, compression gzip

Docker logs (toutes machines) :
  daemon.json : max-size 10m, max-file 3

Logs système (auth.log, syslog) :
  logrotate Debian par défaut (hebdomadaire, 4 rotations)
```

---

## Risques acceptés

| Risque | Impact | Mitigation | Justification |
|--------|--------|------------|---------------|
| NetBird Server sur le VPS | VPS compromis → modification ACLs mesh, ajout peers | Backup config NetBird, monitoring via Bientôt, tunnels WireGuard persistent si management down | Le management doit être joignable pour l'enrollment (impossible en mesh-only) |
| `deploy ALL=(root) NOPASSWD: ALL` | Clé SSH volée → accès root | Code jamais sur le serveur, shell nologin, PermitOpen restrictif, AllowAgentForwarding no, approval GitHub | Ansible a besoin de become sur trop de commandes pour une allowlist sudoers |
| Dépendance GitHub | GitHub down → pas de CI/CD | Procédure d'urgence laptop (voir `05-DEPLOY`) | Le fallback existe mais n'est pas automatique |
| Ntfy public | Accessible sans VPN, spammable si token fuité | Auth Bearer token, tokens séparés lecture/écriture, données non sensibles | L'app mobile a besoin d'un endpoint public pour le push fiable |
| DNS mesh empoisonnable | VPS compromis → modification réponses DNS AdGuard via mesh :53 | ACL NetBird limite VPS à :53 uniquement, AdGuard rejette les requêtes non-DNS | Risque limité : l'attaquant peut rediriger des noms mais pas intercepter le trafic TLS |
| Output HTTPS `0.0.0.0/0:443` | Container compromis (réseau non-internal) → exfiltration vers n'importe quel serveur HTTPS | Réseaux Docker `internal: true` bloquent la majorité des containers. Seuls Traefik, CrowdSec et Docker daemon ont accès au réseau host | Nécessaire pour GHCR, Let's Encrypt, CrowdSec Central API, API DNS providers. Les IPs changent, impossible de pinner |

---

## VLAN

Non traité dans cette version. Isolation du Pi dans un VLAN dédié sur le switch Netgear = hardening supplémentaire. L'architecture ne dépend pas du VLAN. À ajouter en dernier.
