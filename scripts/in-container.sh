#!/usr/bin/env bash
# Entry point inside the privileged builder container:
# GNOME 51 backport, apfs-fuse, icloud-linux -> rootfs -> ISO.
set -euo pipefail
export CACHE_DIR=/cache
export ROOTFS=/cache/work/rootfs
export WORK=/cache/work
export OVERLAY=/src/overlay
export GNOME_REPO=/cache/gnome-repo
export GNOME_PATCH_DIR=/src/patches/gnome
export APFS_FUSE_OUT=/cache/apfs-fuse
export ICLOUD_LINUX_OUT=/cache/icloud-linux
export ISO_OUT="/out/$ISO_NAME"

/src/scripts/build-gnome.sh
/src/scripts/build-apfs-fuse.sh
/src/scripts/build-icloud-linux.sh
/src/scripts/build-rootfs.sh
/src/scripts/build-iso.sh
