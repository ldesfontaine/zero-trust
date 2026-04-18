# Rôle : _shared

## Objectif
**PAS un rôle déployable.** Placard à outils partagés que les vrais rôles incluent via `include_tasks`.

## Contenu
- `tasks/check_network_drift.yml` — vérifie qu'un réseau Docker existant n'a pas un `internal` divergent. Cf. `docker.md` (drift réseau).

## Utilisation
Depuis n'importe quel rôle, avant la task qui déploie le `docker-compose.yml` :
```yaml
- name: "<Service> — Verifier le drift reseau"
  ansible.builtin.include_tasks: "{{ playbook_dir }}/../roles/_shared/tasks/check_network_drift.yml"
  vars:
    network_name: "{{ <service>_network_name }}"
    network_internal: true   # ou false avec justification (cf. docker.md)
```

## Pourquoi `{{ playbook_dir }}/../` ?
Le chemin absolu permet l'inclusion depuis n'importe quel rôle. `ansible-lint` génère un faux-positif `load-failure` sur ce pattern — ignorer.

## À ne pas faire
- Ne pas ajouter `defaults/`, `templates/`, `handlers/` — ce n'est pas un rôle, juste un dossier de tasks réutilisables.
- Ne pas l'appeler via `include_role` — uniquement `include_tasks`.
