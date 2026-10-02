#!/usr/bin/env bash
# Builds a minimal live Ubuntu ISO, dist/ubuntu-live-<arch>[-hardware].iso:
# Ubuntu 26.04 LTS with a minimal GNOME 50 (26.04's own) and GDM, EFI boot and a btrfs root with the subvolumes @, @home,
# @var and @snapshots.
#
# Two flavours: for QEMU (the default: the "virtual" kernel cut down to what
# a VM needs, no firmware; what the releases ship) and, with --hardware, for
# real computers (the generic kernel, all of linux-firmware, CPU microcode:
# what install.sh --on-usb writes to a USB stick).
#
# Runs on macOS (Apple Silicon) through podman: the build happens inside a
# privileged Ubuntu container of the ISO's architecture. arm64 is native on
# Apple Silicon; amd64 (--arch x86) runs emulated in the podman machine
# (qemu-user), which is slow. Also works
# on a Linux host with podman, natively for its own architecture.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./build.sh [--arch arm|x86] [--hardware] [--xkb LAYOUT] [--oauth-clients FILE] [--clean]

  --arch ARCH    arm (arm64, the default) or x86 (amd64)
  --hardware     for real computers: the generic kernel, all of
                 linux-firmware, CPU microcode (dist/ubuntu-live-<arch>-hardware.iso)
  --xkb LAYOUT   keyboard layout for the session and the login screen
                 (default: us, e.g. it)
  --oauth-clients FILE
                 the Backup app's own OAuth clients, a JSON file:
                 {"drive": {"client_id": "...", "client_secret": "..."},
                  "onedrive": {...}, "dropbox": {...}} (any of them).
                 Without one, Google Drive, OneDrive and Dropbox use
                 rclone's, which Google often rate-limits
  --clean        drop the build cache of that architecture (rebuilt GNOME
                 packages, rootfs)
EOF
}

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
dist_dir="$project_dir/dist"
arch=arm64
hardware=0
xkb_layout=us
oauth_clients=""
clean=0
while (($#)); do
  case "$1" in
    --arch)
      (($# >= 2)) || { usage >&2; exit 64; }
      case "$2" in
        arm|arm64|aarch64) arch=arm64 ;;
        x86|x86_64|amd64) arch=amd64 ;;
        *) usage >&2; exit 64 ;;
      esac
      shift 2 ;;
    --hardware) hardware=1; shift ;;
    --xkb) (($# >= 2)) || { usage >&2; exit 64; }; xkb_layout=$2; shift 2 ;;
    --oauth-clients)
      (($# >= 2)) || { usage >&2; exit 64; }
      oauth_clients=$(cat "$2") || exit 1
      shift 2 ;;
    --clean) clean=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

# Per architecture: the builder image and the cache (the rebuilt GNOME
# .debs are arm64 or amd64). The arm64 ones keep their old names. The cache
# is GNOME 50's own: the GNOME 51 builds (branch main) keep theirs.
builder_image() { [[ $1 == arm64 ]] && echo try-ubuntu-builder || echo "try-ubuntu-builder-$1"; }
image=$(builder_image "$arch")
cache_volume=try-ubuntu-gnome50-cache
if [[ $arch == amd64 ]]; then
  cache_volume+=-amd64
fi
iso_name=ubuntu-live-$arch.iso
if ((hardware)); then
  iso_name=ubuntu-live-$arch-hardware.iso
fi
case $arch in
  arm64) mirror=http://ports.ubuntu.com/ubuntu-ports ;;
  amd64) mirror=http://archive.ubuntu.com/ubuntu ;;
esac

if ((clean)); then
  podman volume rm -f "$cache_volume" >/dev/null && echo "Build cache removed ($arch)."
  exit 0
fi

command -v podman >/dev/null || {
  echo "podman is required: brew install podman && podman machine init --now" >&2
  exit 1
}
if [[ $(uname -s) == Darwin ]] && ! podman machine inspect --format '{{.State}}' 2>/dev/null | grep -qx running; then
  echo "==> Starting the podman machine"
  podman machine start
fi
host_arch=$(podman info --format '{{.Host.Arch}}')
if [[ $host_arch != "$arch" ]]; then
  # qemu-user through binfmt_misc: the podman machine has it, a Linux host
  # needs qemu-user-static (or podman build fails on the first RUN)
  echo "==> Building $arch on $host_arch: emulated, it takes a long time"
fi

echo "==> Builder image ($arch)"
# --platform, always: the local ubuntu:26.04 may be the other
# architecture's after a build of it.
podman build -q --platform "linux/$arch" -t "$image" -f "$project_dir/Containerfile" \
  "$project_dir" >/dev/null
if [[ $host_arch != "$arch" ]]; then
  # The ISO step runs natively (see below): the host's builder too
  podman build -q --platform "linux/$host_arch" -t "$(builder_image "$host_arch")" \
    -f "$project_dir/Containerfile" "$project_dir" >/dev/null
fi
podman volume exists "$cache_volume" || podman volume create "$cache_volume" >/dev/null

mkdir -p "$dist_dir"
# --privileged plus the host's /dev: the ISO step loop-mounts the btrfs image
# (to add the snapper snapshot), and loop devices are created on demand.
# ISO_LABEL is the live medium's label and PERSIST_SERIAL the serial of the
# persistent disk (run-qemu.sh --persist): btrfslive looks for both.
# The cache volume holds the rootfs, with device nodes (debootstrap writes
# to its /dev/null) and setuid files: podman 6 mounts named volumes nodev
# and nosuid unless told otherwise.
# builder PLATFORM IMAGE STEPS...: the build steps in a builder container
builder() {
  local platform=$1 builder_image=$2; shift 2
  podman run --rm --privileged --platform "linux/$platform" \
    -v /dev:/dev \
    -v "$cache_volume:/cache:dev,suid" \
    -v "$project_dir:/src:ro" \
    -v "$dist_dir:/out" \
    -e XKB_LAYOUT="$xkb_layout" \
    -e OAUTH_CLIENTS="$oauth_clients" \
    -e SUITE=resolute \
    -e MIRROR="$mirror" \
    -e ARCH="$arch" \
    -e HARDWARE="$hardware" \
    -e EMULATED="$([[ $host_arch != "$arch" ]] && echo 1 || echo 0)" \
    -e ISO_LABEL=UBUNTU_LIVE \
    -e PERSIST_SERIAL=ubuntu-persist \
    -e ISO_NAME="$iso_name" \
    "$builder_image" /src/scripts/in-container.sh "$@"
}
if [[ $host_arch == "$arch" ]]; then
  builder "$arch" "$image"
else
  # Emulated: everything but the ISO step, whose btrfs ioctls (snapshot,
  # resize) qemu-user can't pass on. That one handles the rootfs as files
  # only, so it runs natively, on the same cache.
  builder "$arch" "$image" gnome apfs icloud rootfs
  builder "$host_arch" "$(builder_image "$host_arch")" iso
fi

echo
echo "Done: $dist_dir/$iso_name"
if ((hardware)); then
  echo "Write it to a USB stick with: ./install.sh --on-usb (or dd)"
else
  echo "Boot it with: ./run-qemu.sh$([[ $arch == amd64 ]] && echo " --iso $dist_dir/$iso_name")"
fi
