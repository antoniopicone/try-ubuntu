#!/usr/bin/env bash
# Entry point inside the privileged builder container:
# GNOME 51 backport -> rootfs -> ISO.
set -euo pipefail
export CACHE_DIR=/cache
export ROOTFS=/cache/work/rootfs
export WORK=/cache/work
export OVERLAY=/src/overlay
export GNOME_REPO=/cache/gnome-repo
export GNOME_PATCH_DIR=/src/patches/gnome
export ISO_OUT="/out/$ISO_NAME"

/src/scripts/build-gnome.sh
/src/scripts/build-rootfs.sh
/src/scripts/build-iso.sh
