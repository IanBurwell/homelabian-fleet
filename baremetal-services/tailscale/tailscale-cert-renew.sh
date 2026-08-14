#!/bin/bash

tailscale cert \
    --cert-file "{{ https_certs_dir }}/{{ tailscale_fqdn }}.crt" \
    --key-file "{{ https_certs_dir }}/{{ tailscale_fqdn }}.key" \
    "{{ tailscale_fqdn }}"
