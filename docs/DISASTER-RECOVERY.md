# Disaster Recovery — Tout reconstruire de zéro

## Scénario : Pi mort, nouveau hardware

1. **VPS** (si aussi mort) :
   ```bash
   cd terraform/
   terraform apply
   ```

2. **Bootstrap nouveau Pi** :
   ```bash
   ansible-playbook -i inventory.ini playbooks/bootstrap.yml --limit lan
   ```

3. **Infrastructure** :
   ```bash
   ansible-playbook -i inventory.ini playbooks/infrastructure.yml
   ```

4. **Enrollment NetBird** — manuellement sur le nouveau Pi

5. **Mettre à jour les IPs NetBird** dans `host_vars` et GitHub Secrets

6. **Services** (installe les containers vides) :
   ```
   workflow_dispatch → playbook: playbooks/services.yml
   ```

7. **Restaurer les données** :

   Option A — SSD USB (restauration complète) :
   ```bash
   # Brancher le SSD USB → taper la passphrase LUKS
   ansible-playbook -i inventory.ini playbooks/restore.yml --limit lan -e restore_source=usb
   ```

   Option B — Backup VPS (données critiques uniquement) :
   ```bash
   ansible-playbook -i inventory.ini playbooks/restore.yml --limit lan -e restore_source=vps
   ```
   Il faut la clé GPG privée (dans Vaultwarden ou sur le SSD USB).

8. **Réactiver backup + alerting** :
   ```
   workflow_dispatch → playbook: playbooks/operations.yml
   ```

## Scénario : VPS compromis

1. `terraform destroy` puis `terraform apply` → nouveau VPS, nouvelle IP
2. Mettre à jour l'IP dans l'inventaire et les DNS
3. `workflow_dispatch → playbook: playbooks/infrastructure.yml` puis `playbooks/services.yml`
4. Les backups chiffrés GPG sur l'ancien VPS sont illisibles (clé privée absente)

## Chaîne de confiance

```
Ta tête → passphrase LUKS → SSD USB → clé GPG privée → déchiffre les backups VPS
```

Le seul secret à mémoriser : la passphrase LUKS du SSD USB.
