# Rôle : base

## Objectif
Socle système commun à toutes les machines : paquets, utilisateurs, SSH durci, firewall nftables.

## Architecture
Exécuté en premier dans `playbooks/site.yml` (play 1). Ordonne :
1. `packages.yml` — installation des paquets système (`base_packages`)
2. `users.yml` — création admin (`base_admin_user`) + deploy (`base_deploy_user`), clés SSH
3. `ssh.yml` — bascule port 22 → `base_ssh_port`, désactive password auth, bascule connexion Ansible sur nouveau port + user deploy (async pour pas couper la session)
4. `nftables.yml` — firewall host avec policy `drop` sur input/output, allowlist explicite + interface mesh `wt0`

## Dépendances
- Aucun rôle requis (c'est le premier)
- Secrets vault : aucun (clés SSH publiques = pas des secrets, dans `host_vars/<machine>.yml`)
- `pre_tasks` de `site.yml` auto-résout le port SSH (22 ou `base_ssh_port`)

## Variables
Voir `defaults/main.yml`. Principales :
- `base_ssh_port` — port durci (défaut 2222)
- `base_admin_user` / `base_deploy_user`
- `base_nftables_input_tcp_allow` / `input_udp_allow` / `output_allow`
- `base_nftables_enable_mesh` — active `iifname/oifname wt0 accept` (activer quand NetBird est présent)

## Utilisation
Toujours en premier rôle dans le play :
```yaml
roles:
  - role: base
    tags: [base]
```

## Contrats respectés
- SSH hardening : restart en `async: 1, poll: 0` (sinon coupe la connexion), switch port/user/clé centralisé dans `ssh.yml`
- nftables : policy `drop` sur input/output, interface mesh `wt0` via `iifname`/`oifname` (pas `iif`/`oif`), `validate: nft -c` sur le template
- User deploy jamais dans le groupe `docker`

## Testing
```bash
# SSH durci
ssh -p <base_ssh_port> deploy@<host> "echo OK"

# Firewall actif
sudo nft list ruleset | head -40
# → policy drop sur input/output, table inet filter seule

# Pas de port 22 ouvert
nc -zv <host> 22 2>&1   # connection refused
```
