# Ajouter une nouvelle machine

## 1. Déclarer dans l'inventaire

```ini
# inventory.ini
[pi]
pi_serv    ansible_host=192.168.1.21 ansible_user=admin ansible_port=22 ansible_python_interpreter=/usr/bin/python3
brain-02   ansible_host=192.168.1.YY ansible_user=admin ansible_port=22 ansible_python_interpreter=/usr/bin/python3
```

Note : le groupe `[pi]` est utilisé par tous les playbooks (`hosts: pi`).
Le groupe `[vps]` est réservé au VPS.

## 2. Créer les host_vars

```bash
cp host_vars/pi_serv.yml.example host_vars/brain-02.yml
# Remplir les valeurs
ansible-vault encrypt host_vars/brain-02.yml
```

## 3. Onboard (depuis ton PC local)

```bash
ansible-playbook -i inventory.ini playbooks/onboard.yml --limit brain-02
```

Ceci exécute L0 (bootstrap) + L1-L3 (infrastructure).

## 4. Enrollment NetBird

```bash
# Sur la nouvelle machine
sudo netbird up --setup-key <KEY>
```

Récupérer l'IP NetBird et la mettre dans `host_vars/brain-02.yml`.

## 5. Déployer les services (GitHub Actions)

```
workflow_dispatch → playbook: playbooks/services.yml, limit: brain-02
```

Les ACLs NetBird se mettent à jour automatiquement : le rôle `netbird-acl` lit l'inventaire et crée les groupes/policies pour toutes les machines déclarées.
