# Homelabian Fleet Agent Guide

## Project Shape

- This is an Ansible repository for configuring homelabian-mini servers.
- Run commands from the repository root. `ansible.cfg` supplies `inventory.ini`, `roles/`, `vault.pass`, and `become.pass`.
- `playbooks/provision_m710q.yml` is for first-boot provisioning of an unprovisioned host. It prepares storage, installs/authenticates Tailscale, sets the hostname, and updates the user.
- `playbooks/deploy.yml` configures the established `homelabian-m710q` host. It composes the `common-mini`, `mdadm_array`, `docker`, and service roles.
- Service roles generally render `templates/docker-compose.yml` into their data directory and manage it with `community.docker.docker_compose_v2`.
- Put shared variables in `group_vars/all.yml`; keep role defaults in each role's `defaults/main.yml` and role behavior in `tasks/main.yml`.

## Verification

Use these checks before or after Ansible changes:

```sh
ansible-playbook playbooks/deploy.yml --syntax-check
ansible-playbook playbooks/provision_m710q.yml --syntax-check
ansible-playbook playbooks/deploy.yml --list-tasks
ansible-playbook playbooks/provision_m710q.yml --list-tasks
ansible-lint playbooks/deploy.yml playbooks/provision_m710q.yml roles
ansible-inventory --graph
ansible-inventory --list
ansible-config view
ansible-config dump
ansible-galaxy collection list
ansible-doc ansible.builtin.file
ansible localhost -i localhost, -c local -m ansible.builtin.debug -a "var=hostvars[inventory_hostname]"
ansible localhost -i localhost, -c local -m ansible.builtin.setup
```

There is no application test suite; syntax checks and `ansible-lint` are the primary repository checks. Use `ansible-doc <module>` to inspect module behavior and `ansible-config view` or `ansible-config dump` to verify effective configuration. Use `--check` for a dry run when the target and module support it, but do not treat check mode as a complete simulation of disk, package, Docker, or command operations.

## Safety And Conventions

- Treat `playbooks/provision_m710q.yml` and `roles/provision_storage/` as destructive: verify the target inventory host and disk layout before running them.
- Never print, commit, or replace the contents of `vault.pass`, `become.pass`, or `tailscale.pass`. Pass sensitive values through the existing Ansible Vault/password-file workflow or protected extra variables.
- Preserve idempotency. Prefer Ansible modules and fully qualified module names such as `ansible.builtin.file`; use commands only when no suitable module exists and declare their change/failure behavior.
- Keep service configuration in role templates and variables rather than hard-coding changes on managed hosts. Respect the existing `when: not ansible_check_mode` guards around operations that cannot safely run in check mode.
- Use YAML and Jinja style consistent with the nearby role files; make focused changes and avoid unrelated refactors.

See [README.md](README.md) for developer-container setup, credentials prerequisites, and operational examples.
