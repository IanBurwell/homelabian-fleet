# Homelabian Fleet Agent Guide

## Core Directives (Communication & Output)
- **Strict Conciseness:** Answer questions directly in the first sentence. Do not include conversational filler, greetings, or sign-offs (e.g., "Sure, I can help with that," "Let me know if you need anything else").
- **Code-First Output:** When asked for code changes keep explanations to a maximum of 2–3 bullet points *only* if architectural decisions require clarification.
- **No Unnecessary Narratives:** Do not narrate your thought process or summarize what you just did unless a command fails or an edge case is discovered.
- **Formatting:** Use simple bulleted lists or compact tables for multi-item responses. Keep paragraphs under 3 sentences.

## Execution & Verification Workflow
1. **Read First:** Inspect the target file(s) before proposing changes.
2. **Minimal Diff:** Apply the smallest possible change that satisfies the prompt.
3. **Stop Condition:** Once the specific task passes verification, stop immediately. Do not suggest next steps, follow-up features, or additional optimizations.

## Project Shape

- Run ansible commands from the homelabian-fleet repository root. `ansible.cfg` supplies `inventory.ini`, `roles/`, `vault.pass`, and `become.pass`.
- `playbooks/provision_*.yml` are for first-boot provisioning of an unprovisioned host, configuring things like storage, hostname, and user. 
- `playbooks/deploy.yml` configures the established hosts with any additional services.
- Service roles generally render `templates/docker-compose.yml` into their data directory and manage it with `community.docker.docker_compose_v2`.
- Put shared variables in `group_vars/all.yml`; keep role defaults in each role's `defaults/main.yml` and role behavior in `tasks/main.yml`.

## Verification

When running in a read-only `/root` sandbox, export these environment variables before running Ansible or `ansible-lint` commands so temporary directories remain writable and workspace collections resolve:

```sh
export ANSIBLE_HOME=/tmp/.ansible
export ANSIBLE_COLLECTIONS_PATH=/workspaces/homelabian-fleet/.ansible/collections:/usr/share/ansible/collections
export XDG_CACHE_HOME=/tmp/.cache
```

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

- Treat playbooks as destructive and never run them directly without `--check`, and ensure that checks will not cause mutable changes.
- Never print, commit, or replace the contents of any `.pass` file. Pass sensitive values through the existing Ansible Vault/password-file workflow or protected extra variables.
- Preserve idempotency. Prefer Ansible modules and fully qualified module names such as `ansible.builtin.file`; use commands only when no suitable module exists and declare their change/failure behavior.
- Keep service configuration in role templates and variables rather than hard-coding changes on managed hosts. Respect the existing `when: not ansible_check_mode` guards around operations that cannot safely run in check mode.
- Use YAML and Jinja style consistent with the nearby role files; make focused changes and avoid unrelated refactors.

See [README.md](README.md) for developer-container setup, credentials prerequisites, and operational examples.
