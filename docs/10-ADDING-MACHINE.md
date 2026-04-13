# 10 — Ajouter une machine

## Prérequis

- La machine est accessible en SSH (password ou clé temporaire)
- Le mesh NetBird est UP (Phase 1 complétée sur VPS + Pi)
- Au moins un peer admin enrôlé (laptop ou phone)

## Procédure

### 1. Inventaire

Ajouter la machine dans `inventory.ini` :
```ini
[lan]
pi_serv ansible_host=192.168.1.X ...
minipc_serv ansible_host=192.168.1.Y ansible_user=admin ansible_port=22 ansible_python_interpreter=/usr/bin/python3
```

Si la machine a un rôle fonctionnel distinct du Pi, créer un sous-groupe :
```ini
[storage]
pi_serv ...

[compute]
minipc_serv ...

[lan:children]
storage
compute
```

### 2. Variables

Créer `host_vars/minipc_serv.yml` :
```yaml
# Bootstrap
vault_minipc_bootstrap_user: "admin"
vault_minipc_bootstrap_password: "CHANGE_ME"

# Connexion finale
vault_minipc_ssh_port: 2224    # port custom UNIQUE

# Chemins
minipc_stack_dir: "/opt/stack"   # ou /mnt/tank/stack si ZFS

# NetBird (renseigner après enrollment)
host_netbird_ip: "CHANGE_ME"
```

Chiffrer : `ansible-vault encrypt host_vars/minipc_serv.yml`

### 3. Bootstrap

Ajouter un play dans `bootstrap.yml` pour la nouvelle machine, ou :
```bash
ansible-playbook -i inventory.ini playbooks/bootstrap.yml --limit minipc_serv --ask-vault-pass
```

### 4. Phase 1 — Infrastructure

La machine a besoin de : `common` + `base-pi` (ou `base-vps` si DMZ) + `docker` + `netbird-client`.

Option A — Ajouter la machine dans `infrastructure.yml` :
```yaml
- name: "Infrastructure minipc"
  hosts: compute
  become: true
  gather_facts: false
  pre_tasks:
    - include_role: { name: connection-resolver }
      tags: [always]
    - include_role: { name: netbird-client, tasks_from: resolve.yml }
      tags: [always]
  roles:
    - { role: common,         tags: [common] }
    - { role: base-pi,        tags: [base] }      # UFW, pas nftables
    - { role: docker,         tags: [docker] }
    - { role: netbird-client, tags: [netbird-client] }
```

Option B — Créer un playbook dédié `playbooks/minipc.yml`.

### 5. Enrollment NetBird

```bash
ssh lucas@<MINIPC> -p <PORT>
sudo netbird up --setup-key <KEY> --management-url https://mesh.domain.com
netbird status   # → IP 100.x.x.x → host_vars/minipc_serv.yml
```

### 6. Mettre à jour le mesh

Le nouveau peer doit être dans le bon groupe NetBird. Modifier `mesh-config/tasks/main.yml` :

- Ajouter le peer au groupe `infra` (si c'est une machine d'infra qui a besoin d'accéder au Pi)
- OU créer un nouveau groupe avec des ACLs spécifiques

Relancer :
```bash
ansible-playbook playbooks/mesh-config.yml --ask-vault-pass
```

### 7. Services (si applicable)

Si la machine héberge des containers, créer un rôle `services-minipc` ou ajouter les containers dans un rôle existant.

L'agent Bientôt doit tourner sur la nouvelle machine :
- Ajouter un container `bientot-agent` dans le compose de la machine
- Créer un token dédié : `vault_bientot_token_minipc`
- Ajouter le token côté serveur Bientôt (dans `brain.env.j2`)

### 8. Relancer la config

```bash
ansible-playbook playbooks/infrastructure.yml --limit minipc_serv --ask-vault-pass
# Si services :
ansible-playbook playbooks/services.yml --limit minipc_serv --ask-vault-pass
ansible-playbook playbooks/mesh-config.yml --ask-vault-pass
```

---

## Checklist résumée

```
□ inventory.ini — machine ajoutée dans le bon groupe
□ host_vars/ — créé et chiffré (port SSH unique, IPs)
□ bootstrap.yml — user admin créé
□ infrastructure.yml — play ajouté pour la machine
□ NetBird — enrôlé, IP notée dans host_vars
□ mesh-config — peer dans le bon groupe, ACLs si besoin
□ Bientôt agent — container + token si la machine est monitorée
□ services — rôle créé ou existant étendu si containers
□ monitoring — health-check déployé sur la machine
```
