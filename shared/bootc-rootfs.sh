#!/usr/bin/env bash

set -xeuo pipefail

# Remove directories that ostree/bootc manages via symlinks
rm -rf /boot /home /root /usr/local /srv /opt /mnt /var \
       /usr/lib/sysimage/log /usr/lib/sysimage/cache/pacman/pkg

mkdir -p /sysroot /boot /usr/lib/ostree /var

# Set up the required ostree symlinks
ln -sT sysroot/ostree /ostree
ln -sT var/roothome   /root
ln -sT var/srv        /srv
ln -sT var/opt        /opt
ln -sT var/mnt        /mnt
ln -sT var/home       /home
ln -sT ../var/usrlocal /usr/local

# Ensure volatile directories are created at boot via tmpfiles.d
printf '%s\n' \
    "d /var/opt      0755 root root -" \
    "d /var/home     0755 root root -" \
    "d /var/srv      0755 root root -" \
    "d /var/mnt      0755 root root -" \
    "d /var/usrlocal 0755 root root -" \
    | tee -a /usr/lib/tmpfiles.d/bootc-base-dirs.conf

printf 'd /var/roothome 0700 root root -\nd /run/media 0755 root root -\n' \
    | tee -a /usr/lib/tmpfiles.d/bootc-base-dirs.conf

# Ubuntu packages expect these /var/lib subdirs to exist at runtime.
# Since /var is a separate dataset (starts empty on first boot), create them
# via tmpfiles.d so systemd-tmpfiles-setup.service handles it.
printf '%s\n' \
    "d /var/lib/update-notifier  0755 root root -" \
    "d /var/lib/ubuntu-advantage 0755 root root -" \
    "d /var/lib/apport           0755 root root -" \
    | tee -a /usr/lib/tmpfiles.d/bootc-base-dirs.conf

# Enable composefs and read-only sysroot for bootc
printf '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' \
    | tee /usr/lib/ostree/prepare-root.conf
