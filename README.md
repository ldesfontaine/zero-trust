# Zero Trust Homelab

Infrastructure as Code pour homelab Zero Trust.
VPS (DMZ) + Raspberry Pi (privé), mesh WireGuard, reverse proxy TLS, services conteneurisés.

## Stack
- **Ansible** — orchestration idempotente
- **Docker** — runtime containers, socket-proxy pour l'accès API
- **Traefik** — reverse proxy, TLS auto (HTTP-01 ou DNS-01 wildcard)
- **NetBird** — mesh WireGuard (management + signal + relay)
- **nftables** — firewall host, policy `drop`, allowlist stricte

## Architecture
Voir [docs/00-DESIGN.md](docs/00-DESIGN.md) — principes et architecture globale.

Résumé : deux machines, le VPS joue le rôle de DMZ (expose 80/443/3478 public), le Pi reste en zone privée joignable uniquement via le mesh NetBird. Aucun repo n'est cloné sur les serveurs, images uniquement depuis GHCR.

## Déploiement
```bash
# Tout sur une machine
ansible-playbook playbooks/site.yml --limit vps --ask-vault-pass

# Dry-run avant
ansible-playbook playbooks/site.yml --limit vps --ask-vault-pass --check --diff

# Un seul service
ansible-playbook playbooks/update_service.yml \
  -e target_service=portfolio -e target_version=1.4.0 --limit vps
```

## Ajouter un service
Voir [docs/09-ADD-SERVICE.md](docs/09-ADD-SERVICE.md) — checklist complète (DNS → rôle → secrets → deploy).

## Documentation complète
- [docs/00-DESIGN.md](docs/00-DESIGN.md) — principes, architecture globale
- [docs/01-SERVICES.md](docs/01-SERVICES.md) — services par machine, modules, alerting
- [docs/02-ISOLATION.md](docs/02-ISOLATION.md) — réseaux Docker, isolation
- [docs/03-FLUX.md](docs/03-FLUX.md) — flux réseau, ACLs NetBird
- [docs/04-SECURITY.md](docs/04-SECURITY.md) — TLS, hardening, secrets, risques acceptés
- [docs/05-DEPLOY.md](docs/05-DEPLOY.md) — CI/CD, backup, disaster recovery
- [docs/06-ANSIBLE.md](docs/06-ANSIBLE.md) — conventions de code, structure des rôles
- [docs/07-DEVPLAN.md](docs/07-DEVPLAN.md) — plan de dev sprint par sprint
- [docs/08-BOOTSTRAP.md](docs/08-BOOTSTRAP.md) — premier démarrage, token API NetBird
- [docs/09-ADD-SERVICE.md](docs/09-ADD-SERVICE.md) — checklist nouveau service

## Hooks git
À activer après chaque clone (config locale, non versionnée) :
```bash
git config core.hooksPath .githooks
```
Active le hook `pre-commit` qui refuse tout `vault.yml` non chiffré (détection `$ANSIBLE_VAULT`).

## Rôles disponibles
- [base](roles/base/) — socle système (paquets, users, SSH durci, nftables)
- [docker](roles/docker/) — engine + daemon + socket-proxy Tecnativa
- [traefik](roles/traefik/) — reverse proxy TLS, modes `edge` ou `internal`
- [netbird](roles/netbird/) — mesh WireGuard (server / config ACLs / client via `tasks_from`)
- [portfolio](roles/portfolio/) — site statique (termfolio)
- [ntfy](roles/ntfy/) — notifications push (APNs iOS relay)
- [_shared](roles/_shared/) — *pas un rôle* : tasks réutilisables (`check_network_drift`)
