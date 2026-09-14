# Homelabian Fleet - Further setup of my homelab fleet

This repo uses ansible to configure a base homelabian-mini server, adding various settings and services beyond the basic configuration.


# DevContainer Usage (Recommended)
1. Setup [devcontainers](https://code.visualstudio.com/docs/devcontainers/containers#_system-requirements) if you havent used them before
2. Make sure you have an SSH key that is authorized by the server, and that [ssh-agent is running](https://dev.to/aka_anoop/how-to-enable-openssh-agent-to-access-your-github-repositories-on-windows-powershell-1ab8)
2. Open repo in VSCode, and if not promped to run in a devcontainer run `>Reopen In Container` in VSCode.
3. Create `vault.pass` with the Ansible Vault password and `become.pass` with the password of the homelabian server user 
4. Profit


# Baremetal Usage
1. Install ansible via `pipx install --include-deps ansible`
2. Install python packages in the ansible virtual environment via `pipx runpip ansible install -r $(pwd)/requirements.txt`
3. Create `vault.pass` with the Ansible Vault password and `become.pass` with the password of the homelabian server user 
4. Profit

# Resources
- To provision the m710q machine initially run `ansible-playbook provision_m710q.yml -e "new_hostname=homelabian-m710q" -e "tailscale_authkey=$(cat tailscale.pass)"` (TODO generalize this)
- `ansible all -m ping` - pings all servers in inventory
- `ansible all -m ansible.builtin.shell -a "/sbin/reboot"` - reboot all servers in inventory
- `ansible-vault encrypt_string 'var_content' --name 'variable_name'` - generate an encrypted string variable
- `ansible-lint playbooks/deploy.yml` - check validity of a playbook
- Add `--check` to a playbook run to test it and not make any real changes
- `ansible-galaxy install -r requirements.yml` - Dependencies install (auto run in the devcontainer)

#### TODOs
- Determine backup *and restore* system
- Implement mdadm software RAID on m710q
- Implement borgmatic for backups (where should they go though?)
Move frigate `config.yaml` into Ansible
- UFW doesnt work with docker, look at using tailscale as a reverse proxy and setting docker ports to `127.0.0.1:port:dport`
- Document how to run main/setup playbooks
- Find a way to replace the `.pass` files with a `.env`
- Create a better way to test playbook changes without having to actually modify a live server (ex have a containerized test environment simulating each host)
- Find a way to template the ts-serve config required by docker_exted_base
