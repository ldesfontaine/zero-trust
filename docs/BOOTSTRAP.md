# Bootstrap — Procedure Run 0

> Guide pas-a-pas pour deployer l'infrastructure complete depuis zero.
> Managed by Ansible — ne pas modifier manuellement sans raison.

---

## Prerequis

- Ansible installe sur le PC local
- Cle SSH Ed25519 generee (`ssh-keygen -t ed25519`)
- `group_vars/all.yml` et `host_vars/*.yml` remplis et chiffres (`ansible-vault encrypt`)
- Terraform installe (pour le VPS uniquement)
- Acces console Hostinger (filet de securite en cas de lockout SSH)

## Vue d'ensemble

```
 LAPTOP                          VPS                              PI
 ──────                          ───                              ──
 1. Terraform apply              VPS cree (IP publique)
 2. bootstrap.yml (all)          L0: users + SSH                  L0: users + SSH
 3. infrastructure.yml           L1: system + hardening
     --limit vps_serv            L2: Docker
                                 L3a: Traefik (reverse proxy)
                                 L3b: NetBird server + dashboard
                                 L3c: netbird-client (installe, PAS enrole)
 ── PAUSE MANUELLE ──
 4. Dashboard NetBird            Creer 2 setup keys (VPS + Pi)
 5. SSH → VPS                    sudo netbird up --setup-key <KEY_VPS>
 6. infrastructure.yml                                            L1-L2 + netbird-client
     --limit pi_serv
 7. SSH → Pi                                                      sudo netbird up --setup-key <KEY_PI>
 8. services.yml (vps)           L4: CrowdSec, Ntfy, node-exp
 9. services.yml (pi)                                             L4: Seafile, Vaultwarden, etc.
10. operations.yml               L5: backup + alerting            L5: backup + alerting
```

---

## Etape 1 — Creer le VPS (Terraform)

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# Remplir : API token Hostinger, cle SSH publique
terraform init
terraform plan
terraform apply
# Output → IP publique du VPS → la mettre dans inventory.ini
```

## Etape 2 — Bootstrap des machines (L0)

```bash
# VPS (root + password Hostinger)
ansible-playbook playbooks/bootstrap.yml --limit dmz

# Pi (user par defaut + password)
ansible-playbook playbooks/bootstrap.yml --limit lan
```

Resultat : user admin (lucas) + user deploy + cles SSH injectees sur les 2 machines.

> **Note** : `bootstrap.yml` ne passe PAS par le connection-resolver.
> Il gere sa propre cascade (root → admin) car les users n'existent pas encore.

## Etape 3 — Infrastructure VPS (L1-L3)

```bash
ansible-playbook playbooks/infrastructure.yml --limit vps_serv
```

Ce play execute dans l'ordre :
1. **L1** — `system-vps` + `hardening-vps` (apt, nftables, SSH hardening)
2. **L2** — `docker` (Docker engine)
3. **L3a** — `traefik` (reverse proxy + TLS dans `/opt/backbone/`)
4. **L3b** — `netbird-server` (serveur mesh + dashboard dans `/opt/backbone/`)
5. **L3c** — `netbird-client` (daemon installe, PAS enrole)

Le connection-resolver detecte automatiquement le port SSH (22 au premier run, durci ensuite).

### Architecture Docker VPS — 2 stacks separees

| Stack | Repertoire | Layer | Contenu |
|-------|-----------|-------|---------|
| **Backbone** | `/opt/backbone/` | L3 | Traefik + NetBird server + dashboard |
| **Services** | `/opt/sentinel/` | L4 | CrowdSec + Ntfy + node-exporter |

Les 2 stacks partagent le reseau Docker `sentinel_net` (declare `external: true`).
Traefik route les services L4 via labels Docker et le provider file pour les services Pi.

## Etape 4 — Enrollment NetBird (PAUSE MANUELLE)

1. Ouvrir `https://mesh.ldesfontaine.com` (le dashboard est accessible via Traefik)
2. Creer **2 setup keys** (usage unique, expiration courte) : une VPS, une Pi

### Enroler le VPS

```bash
ssh lucas@<VPS_IP>
sudo netbird up --setup-key <KEY_VPS> --management-url https://mesh.ldesfontaine.com
netbird status  # → noter l'IP WireGuard (100.x.x.x)
```

Mettre a jour `host_vars/vps_serv.yml` :
```yaml
vault_vps_netbird_ip: "100.x.x.x"
```

## Etape 5 — Infrastructure Pi (L1-L3)

```bash
ansible-playbook playbooks/infrastructure.yml --limit pi_serv
```

Le connection-resolver tente l'IP LAN d'abord, fallback sur NetBird si non joignable.
Ce play execute : `system-pi` → `hardening-pi` → `docker` → `netbird-client`.

### Enroler le Pi

```bash
ssh lucas@<PI_IP>
sudo netbird up --setup-key <KEY_PI> --management-url https://mesh.ldesfontaine.com
netbird status  # → noter l'IP WireGuard (100.x.x.x)
```

Mettre a jour `host_vars/pi_serv.yml` :
```yaml
vault_pi_netbird_ip: "100.x.x.x"
```

## Etape 6 — Recuperer les IPs NetBird et configurer GitHub Secrets

Ajouter dans GitHub Secrets :
- `ANSIBLE_VAULT_PASSWORD` — passphrase du vault
- `SSH_PRIVATE_KEY` — cle du user deploy (PAS admin)

Re-chiffrer les host_vars :
```bash
ansible-vault encrypt host_vars/vps_serv.yml host_vars/pi_serv.yml
```

## Etape 7 — Services applicatifs (L4)

A partir de maintenant, tout peut se faire via `workflow_dispatch` :

```bash
# Ou depuis le laptop :
ansible-playbook playbooks/services.yml --limit vps_serv
ansible-playbook playbooks/services.yml --limit pi_serv
```

Le role `netbird-resolve` calcule automatiquement `netbird_bind_ip` par host.
Si le mesh est UP → binding sur l'IP NetBird. Sinon → fallback `127.0.0.1`.

## Etape 8 — Operations (L5)

```bash
ansible-playbook playbooks/operations.yml
```

Backup modulaire + alerting Ntfy.

---

## Apres le Run 0

Tout passe par GitHub Actions (`workflow_dispatch`). Le VPS est le bastion.
Le connection-resolver detecte automatiquement :
- **Connexion** : `local` si Ansible tourne sur le VPS, `ssh` sinon
- **Route Pi** : LAN d'abord, NetBird en fallback
- **Port SSH** : durci d'abord, 22 en fallback

Plus besoin de `ci_mode` ni d'intervention manuelle.

---

## Troubleshooting

### Le dashboard NetBird n'est pas accessible (etape 4)

- Verifier que Traefik tourne : `docker compose -f /opt/backbone/docker-compose.backbone.yml ps`
- Verifier les certificats : `docker compose -f /opt/backbone/docker-compose.backbone.yml logs traefik | grep -i acme`
- Verifier le DNS : le sous-domaine `mesh.*` pointe sur l'IP publique du VPS

### Le Pi est injoignable (etape 5)

Le connection-resolver affiche un message explicite :
```
Pi injoignable sur tous les chemins.
LAN (192.168.1.x) : ECHEC
NetBird (100.x.x.x) : ECHEC
```

- Verifier que le Pi est allume et sur le reseau
- Depuis le laptop : `ping <PI_LAN_IP>`
- Si depuis le VPS : verifier que NetBird est UP sur le VPS (`netbird status`)

### Le bouncer CrowdSec ne demarre pas (etape 7)

- Le LAPI met du temps au premier demarrage (telechargement du hub)
- Le role `crowdsec-bouncer` attend jusqu'a 90s avec 10 retries
- Verifier : `docker exec crowdsec cscli lapi status`
- Verifier les flux sortants : `nft list table inet filter` (chain forward doit autoriser 53/443)
