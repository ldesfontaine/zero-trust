# Role crowdsec

## Objectif

Deploie CrowdSec en deux etapes distinctes :

- **Engine** (Phase 1) — container Docker qui detecte les attaques a partir
  des logs SSH (`/var/log/auth.log`) et Traefik (`access.log` JSON). Expose
  la LAPI sur `127.0.0.1:8080`. NE BLOQUE RIEN.
- **Bouncer** (Phase 2) — paquet apt host qui poll la LAPI et banit les IPs
  malveillantes via `nftables` (table dediee `inet crowdsec`, priority -10).

La separation permet d'observer 24-48h avant d'activer le blocage effectif
(ajuster les whitelists, tuner les scenarios, eviter l'auto-ban).

## Utilisation

Le role a plusieurs modes, invocation via `tasks_from` :

```yaml
- include_role:
    name: crowdsec
    tasks_from: engine.yml    # Phase 1

- include_role:
    name: crowdsec
    tasks_from: bouncer.yml   # Phase 2 (quand le fichier existera)
```

Activation dans `inventory/host_vars/<host>/main.yml` :

```yaml
machine_crowdsec:
  engine: true
  bouncer: false   # tant que Phase 1 n'est pas validee en observation
```

## Dependances

- **Role `traefik`** doit tourner avant (cree le volume `traefik-edge-logs`).
- **`traefik_enable_crowdsec: true`** dans host_vars du VPS, sinon le volume
  des logs Traefik n'existe pas et l'engine `fail` explicitement.
- **Docker Compose v2** (installe par le role `docker`).

## Contrats respectes

- **CONTRAT A** (`docker.md`) : reseau nomme `crowdsec-net`.
- **CONTRAT B** : non applicable — CrowdSec n'est PAS derriere Traefik,
  pas de label `traefik.docker.network`.
- **`internal: false`** sur le reseau : justifie par l'appel a la Central
  API (`api.crowdsec.net`) — documente dans `docker.md`.
- **Bind mount** pour la persistance (cf. `tls-backup.md` — pattern projet).

## Secrets

Aucun secret requis en Phase 1 (sans enrollment Console).

Si `crowdsec_console_enrollment_enabled: true` en host_vars, renseigner
`vault_crowdsec_enrollment_key` dans `inventory/host_vars/<host>/vault.yml`.

## Verifications post-deploy

```bash
ssh vps
docker logs crowdsec --tail 50
docker exec crowdsec cscli lapi status
docker exec crowdsec cscli collections list
docker exec crowdsec cscli metrics              # lignes lues / parsed
docker exec crowdsec cscli alerts list
docker exec crowdsec cscli decisions list       # vide en Phase 1
```

Ce qu'il faut voir apres 10 min :
- `cscli metrics` : lignes lues sur syslog ET traefik.
- Aucune alerte sur les IPs whitelistees (home, mesh).

Apres 24-48h d'observation, si les detections sont fiables → Phase 2 (bouncer).

## Phase 2 — Bouncer nftables

Le bouncer est installe sur l'host (paquet apt, pas container) car il doit
modifier les regles nftables kernel — impossible proprement depuis un
container isole. Il poll l'Engine via `127.0.0.1:8080` et ajoute les IPs
bannies dans une table nftables dediee (`inet crowdsec`, priority -10).

### Prerequis

- Engine deploye et fonctionnel (`machine_crowdsec.engine: true`).
- Secret dans le vault : `vault_crowdsec_bouncer_api_key`
  (generer via `openssl rand -hex 32` puis `ansible-vault edit ...`).
- Table `inet filter` (role `base`) a priority >= 0 — le bouncer a -10
  passe donc avant.

### Activation

```yaml
# inventory/host_vars/vps/main.yml
machine_crowdsec:
  engine: true
  bouncer: true
```

```bash
ansible-playbook playbooks/site.yml --limit vps \
  --ask-vault-pass --tags crowdsec-bouncer
```

### Architecture nftables

Le bouncer cree sa propre table `inet crowdsec` avec priority -10, qui
s'execute AVANT `inet filter` (priority 0). Les IPs bannies sont droppees
au niveau kernel avant toute logique du firewall base.

```
Trafic entrant
    ↓
Table inet crowdsec (priority -10)
    ├── IP dans set crowdsec-blacklists0 → DROP silencieux
    └── sinon                              → passe
    ↓
Table inet filter (priority 0, role base)
    ├── ACCEPT SSH {{ base_ssh_port }}
    ├── ACCEPT HTTPS 443
    └── policy DROP
```

### Verifications post-deploy

```bash
# Service systemd UP
sudo systemctl status crowdsec-firewall-bouncer

# Bouncer enregistre cote Engine (last_pull doit etre recent)
sudo docker exec crowdsec cscli bouncers list

# Tables nftables : doit contenir inet filter + inet crowdsec
sudo nft list tables

# Blocklist CAPI chargee (typiquement ~24k IPs apres 1 min)
sudo nft list set inet crowdsec crowdsec-blacklists0 | wc -l

# Logs du bouncer (journald + fichier dans /var/log/)
sudo journalctl -u crowdsec-firewall-bouncer --since "5 min ago"
```

### Rotation de l'API key

```bash
# 1. Supprimer cote Engine
sudo docker exec crowdsec cscli bouncers delete nftables-vps

# 2. Generer une nouvelle key
openssl rand -hex 32

# 3. Mettre a jour le vault
ansible-vault edit inventory/host_vars/vps/vault.yml

# 4. Redeployer (le bouncer est re-enregistre, config re-templatee)
ansible-playbook playbooks/site.yml --limit vps \
  --ask-vault-pass --tags crowdsec-bouncer
```
