# Homelabian Fleet - Further setup of my homelab fleet

This repo uses ansible to configure a base homelabian-mini server, adding various settings and services beyond the basic configuration.
- Dependencies install (TODO explore improvement): `ansible-galaxy collection install community.general ansible.posix`


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
- To provision a fresh homelabian image initially run `ansible-playbook new-homelabian-setup.yml -e "new_hostname=new-hostname" -e "tailscale_authkey=$(cat tailscale.pass)"` 
- `ansible all -m ping -i inventory.ini` - pings all servers in inventory
- `ansible all -m ansible.builtin.shell -a "/sbin/reboot"` - reboot all servers in inventory
- `ansible-lint playbook.yml` - check validity of a playbook
- `ansible-vault encrypt_string '<string>' --name 'variable_name'` - generate an encrypted string variable
- Add `--check` to a playbook run to test it and not make any real changes
