# Rôle : ntfy

## Objectif
Serveur de notifications push auto-hébergé (`binwiederhier/ntfy`). Relaye les push APNs iOS via `ntfy.sh`. Provisionne le user admin + token d'accès automatiquement.

## Architecture
Container unique en UID/GID non-root (1000:1000). Réseau `ntfy-net` en `internal: false` — **exception justifiée** : ntfy doit contacter `ntfy.sh` pour relayer les push APNs vers les devices iOS (cf. `docker.md`).

Auth deny-all par défaut dans `server.yml.j2`. User admin + token créés au premier run, idempotent (check `token list admin`).

## Dépendances
- Rôles requis : `base`, `docker`, `traefik` (avant ce rôle)
- Secrets vault : `vault_ntfy_admin_password` (user admin)

## Variables
Voir `defaults/main.yml`. UID/GID 1000:1000 (défaut de l'image `binwiederhier/ntfy`).

## Utilisation
```yaml
machine_services:
  - ntfy
  - ...
  - traefik
```

## Contrats respectés
- Réseau `ntfy-net` (contrat A)
- Label `traefik.docker.network=ntfy-net` (contrat B)
- `internal: false` — **exception documentée** : relay ntfy.sh pour APNs iOS
- Hardening : `read_only: true` + `tmpfs: /tmp`, `cap_drop: ALL`, `no-new-privileges`, `healthcheck`
- Idempotence token : commande user-spécifique `token list admin` (cf. bug 2026-04-17 dans `ansible-patterns.md`)

## Testing
```bash
# Health
curl -sI https://ntfy.<base_domain>/v1/health   # → 200

# Token admin unique
docker exec ntfy ntfy token list admin   # → une seule ligne tk_*

# Push de test (depuis un client authentifié)
curl -H "Authorization: Bearer tk_..." -d "hello" https://ntfy.<base_domain>/test
```

Idempotence : relancer le rôle, attendre `changed=0` (pas de nouveau token créé).
