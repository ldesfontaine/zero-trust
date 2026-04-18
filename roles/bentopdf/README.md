# Rôle : bentopdf

## Objectif

Déploie [BentoPDF](https://github.com/alam00000/bentopdf), toolkit PDF 
privacy-first 100% client-side, derrière Traefik Edge sur `pdf.<base_domain>`.

## Architecture

BentoPDF est une **image nginx-unprivileged** (UID 101) qui sert un site 
statique (HTML/JS/WASM). Le traitement PDF (conversion, OCR, signature, etc.) 
se fait **entièrement dans le navigateur du visiteur** via des modules WASM 
(PyMuPDF, Ghostscript, CoherentPDF, Tesseract).

Conséquences côté infrastructure :

- Aucune donnée utilisateur ne transite par le serveur
- Pas de volume persistant (stateless)
- Pas de base de données
- Pas de limites CPU/mémoire nécessaires (zéro traitement serveur)

Le serveur se contente de servir quelques mégaoctets de statique.

## Dépendances

### Rôles requis

- `base` + `docker` (infrastructure socle)
- `traefik` (reverse proxy, connexion au réseau bentopdf-net automatique 
  via `roles/traefik/tasks/connect_networks.yml`)
- `_shared/tasks/check_network_drift.yml` (inclus via `include_tasks`)

### Variables globales requises

Définies dans `inventory/group_vars/all/main.yml` :

- `base_domain` — domaine racine (ex: `ldesfontaine.com`)
- `traefik_wildcard_enabled` — auto-détecté depuis la présence du token 
  Cloudflare dans le vault

### Infrastructure externe

- Record DNS A `pdf.<base_domain>` → IP du VPS (Cloudflare, DNS only / gris)
- Port 443 ouvert sur le VPS (déjà le cas via le rôle `base`)

## Variables

Voir `defaults/main.yml` pour la liste complète. Override dans 
`inventory/host_vars/<machine>/main.yml` si nécessaire.

Variables principales :

| Variable | Défaut | Rôle |
|----------|--------|------|
| `bentopdf_image` | `ghcr.io/alam00000/bentopdf` | Registry + nom de l'image |
| `bentopdf_version` | `v1.16.1` | Tag d'image (pinner, jamais `latest`) |
| `bentopdf_domain` | `pdf.{{ base_domain }}` | FQDN exposé |
| `bentopdf_network_name` | `bentopdf-net` | Nom réseau Docker (CONTRAT A) |
| `bentopdf_port` | `8080` | Port interne du container |
| `bentopdf_data_dir` | `/opt/modules/bentopdf` | Dossier du compose |

## Utilisation

Ajouter `bentopdf` dans `machine_services` de la machine cible 
(`inventory/hosts.yml`) :

```yaml
machine_services:
  - ntfy
  - portfolio
  - bentopdf        # nouveau
  - traefik         # TOUJOURS en dernier
```

Ensuite lancer le playbook :

```bash
ansible-playbook playbooks/site.yml --limit vps --ask-vault-pass
```

## Contrats respectés

- **CONTRAT A** : réseau `bentopdf-net` (tirets, pas underscores)
- **CONTRAT B** : label `traefik.docker.network=bentopdf-net`
- **`internal: true`** : pas de sortie internet requise (service purement 
  client-side)
- **Hardening** : `read_only: true` + `cap_drop: ALL` + 
  `no-new-privileges:true`
- **Healthcheck** : `wget --spider` sur `/` (timeout 3s)
- **Pas de secret** : BentoPDF n'a pas d'auth, pas de vault requis

## Tests

```bash
# Le container est UP
docker ps | grep bentopdf
# STATUS doit montrer "(healthy)"

# Le site répond
curl -sI https://pdf.ldesfontaine.com
# HTTP/2 200

# Le cert est valide (pas auto-signé)
curl -vI https://pdf.ldesfontaine.com 2>&1 | grep -i "issuer"
# issuer: C=US; O=Let's Encrypt; CN=R10 (ou équivalent)
```

## Idempotence

Un 2ème run d'Ansible doit montrer `changed=0` pour toutes les tasks du rôle.
Si une task `changed` à chaque run, c'est un bug d'idempotence — corriger 
avant de commit.

## Sécurité

BentoPDF traite de l'**input non-trusté** (visiteurs anonymes uploadent 
des PDF arbitraires). Cependant :

- Le traitement se fait **dans le navigateur du visiteur**, pas côté serveur
- Le serveur ne voit jamais les fichiers PDF
- La surface d'attaque côté serveur se limite à nginx (audité)
- Pas de CVE spécifique à l'app à surveiller

Pour bumper la version, modifier `bentopdf_version` dans 
`inventory/group_vars/all/versions.yml` et relancer le playbook.

## Références

- Repo officiel : https://github.com/alam00000/bentopdf
- Documentation : https://bentopdf.com (si le site officiel est UP)
- Image GHCR : https://ghcr.io/alam00000/bentopdf