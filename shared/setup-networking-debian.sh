#!/usr/bin/env bash
# Common networking and SSH setup for debian-based bootc images.
# Enables systemd-networkd/resolved, writes a netplan config matching
# cloud-image conventions (DHCP on en*/eth* with use-domains), and
# disables SSH password auth.

set -xeuo pipefail

systemctl enable systemd-networkd systemd-resolved ssh

printf 'L! /etc/resolv.conf - - - - /run/systemd/resolve/stub-resolv.conf\n' \
    > /usr/lib/tmpfiles.d/resolv-conf.conf

mkdir -p /etc/netplan
printf 'network:\n  version: 2\n  ethernets:\n    all-en:\n      match:\n        name: en*\n      dhcp4: true\n      dhcp4-overrides:\n        use-domains: true\n      dhcp6: true\n      dhcp6-overrides:\n        use-domains: true\n    all-eth:\n      match:\n        name: eth*\n      dhcp4: true\n      dhcp4-overrides:\n        use-domains: true\n      dhcp6: true\n      dhcp6-overrides:\n        use-domains: true\n' > /etc/netplan/90-default.yaml

sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config || true
