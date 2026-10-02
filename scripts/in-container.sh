#!/usr/bin/env bash
# Entry point inside the privileged builder container:
# GNOME 51 backport, apfs-fuse, icloud-linux -> rootfs -> ISO.
# With arguments, only those steps (gnome apfs icloud rootfs iso): build.sh
# runs the ISO step apart, in a native container, when the rest is
# emulated (qemu-user can't pass btrfs's ioctls on, which the ISO step uses).
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

steps=("$@")
((${#steps[@]})) || steps=(gnome apfs icloud rootfs iso)
for step in "${steps[@]}"; do
  case $step in
    gnome)  /src/scripts/build-gnome.sh ;;
    apfs)   /src/scripts/build-apfs-fuse.sh ;;
    icloud) /src/scripts/build-icloud-linux.sh ;;
    rootfs) /src/scripts/build-rootfs.sh ;;
    iso)    /src/scripts/build-iso.sh ;;
    *) echo "unknown step: $step" >&2; exit 64 ;;
  esac
done
