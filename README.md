# Homelabian Services - A layer above Homelabian

This repo uses ansible to configure a base Homelabian server, adding various settings and services beyond the basic configuration.


# DevContainer Usage (Recommended)
1. Setup [devcontainers](https://code.visualstudio.com/docs/devcontainers/containers#_system-requirements) if you havent used them before 
2. Open repo in VSCode, and if not promped to run in a devcontainer run `>Reopen In Container` in VSCode. I use docker, but choose your preffered config from the list
3. Create `vault.pass` with the Ansible Vault password and `become.pass` with the password of the homelabian server user 
4. Profit


# Baremetal Usage
1. Install ansible via `pipx install --include-deps ansible`
2. Install python packages in the ansible virtual environment via `pipx runpip ansible install -r $(pwd)/requirements.txt`
3. Create `vault.pass` with the Ansible Vault password and `become.pass` with the password of the homelabian server user 
4. Profit

# Resources
- `ansible all -m ping -i inventory.ini` - pings all servers in inventory
- `ansible all -m ansible.builtin.shell -a "/sbin/reboot"` - reboot all servers in inventory
- `ansible-lint playbook.yml` - check validity of a playbook
- `ansible-vault encrypt_string '<string>' --name 'variable_name'` - generate an encrypted string variable
- 