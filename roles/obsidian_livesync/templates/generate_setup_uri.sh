#!/bin/bash
# Generates a one time setup URI for Obsidian LiveSync cllients

# Prompt for user to enter a URI passphrase
read -p "Enter a URI passphrase (optional): " uri_passphrase

export hostname="https://{{ obsidian_livesync_ts_service }}.{{ tailnet_fqdn }}"
export database="{{ obsidian_livesync_database}}"
export username="{{ obsidian_livesync_couchdb_user }}"
export password="{{ obsidian_livesync_couchdb_password }}"
export passphrase="{{ obsidian_livesync_encryption_passphrase }}"
export uri_passphrase

# Run the Deno script to generate the setup URI
deno run --minimum-dependency-age=0 --allow-env https://raw.githubusercontent.com/vrtmrz/obsidian-livesync/main/utils/setup/generate_setup_uri.ts