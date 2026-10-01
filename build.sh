#!/usr/bin/env bash
# Builds a minimal live Ubuntu ISO (arm64), dist/ubuntu-live-arm64.iso:
# Ubuntu 26.04 LTS with a minimal GNOME 51 (backported from 26.10, compiled
# once) and GDM, EFI boot and a btrfs root with the subvolumes @, @home,
# @var and @snapshots.
#
# Runs on macOS (Apple Silicon) through podman: the build happens inside a
# privileged arm64 Ubuntu container, so nothing is emulated. Also works on an
# arm64 Linux host with podman.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./build.sh [--xkb LAYOUT] [--oauth-clients FILE] [--clean]

  --xkb LAYOUT   keyboard layout for the session and the login screen
                 (default: us, e.g. it)
  --oauth-clients FILE
                 the Backup app's own OAuth clients, a JSON file:
                 {"drive": {"client_id": "...", "client_secret": "..."},
                  "onedrive": {...}, "dropbox": {...}} (any of them).
                 Without one, Google Drive, OneDrive and Dropbox use
                 rclone's, which Google often rate-limits
  --clean        drop the build cache (GNOME backport, rootfs)
EOF
}

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
dist_dir="$project_dir/dist"
image=try-ubuntu-builder
cache_volume=try-ubuntu-cache
iso_name=ubuntu-live-arm64.iso

xkb_layout=us
oauth_clients=""
while (($#)); do
  case "$1" in
    --xkb) (($# >= 2)) || { usage >&2; exit 64; }; xkb_layout=$2; shift 2 ;;
    --oauth-clients)
      (($# >= 2)) || { usage >&2; exit 64; }
      oauth_clients=$(cat "$2") || exit 1
      shift 2 ;;
    --clean)
      podman volume rm -f "$cache_volume" >/dev/null && echo "Build cache removed."
      exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

command -v podman >/dev/null || {
  echo "podman is required: brew install podman && podman machine init --now" >&2
  exit 1
}
if [[ $(uname -s) == Darwin ]] && ! podman machine inspect --format '{{.State}}' 2>/dev/null | grep -qx running; then
  echo "==> Starting the podman machine"
  podman machine start
fi
if [[ $(podman info --format '{{.Host.Arch}}') != arm64 ]]; then
  echo "The podman host must be arm64 (Apple Silicon or arm64 Linux)." >&2
  exit 1
fi

echo "==> Builder image"
podman build -q -t "$image" -f "$project_dir/Containerfile" "$project_dir" >/dev/null
podman volume exists "$cache_volume" || podman volume create "$cache_volume" >/dev/null

mkdir -p "$dist_dir"
# --privileged plus the host's /dev: the ISO step loop-mounts the btrfs image
# (to add the snapper snapshot), and loop devices are created on demand.
# ISO_LABEL is the live medium's label and PERSIST_SERIAL the serial of the
# persistent disk (run-qemu.sh --persist): btrfslive looks for both.
# The cache volume holds the rootfs, with device nodes (debootstrap writes
# to its /dev/null) and setuid files: podman 6 mounts named volumes nodev
# and nosuid unless told otherwise.
podman run --rm --privileged \
  -v /dev:/dev \
  -v "$cache_volume:/cache:dev,suid" \
  -v "$project_dir:/src:ro" \
  -v "$dist_dir:/out" \
  -e XKB_LAYOUT="$xkb_layout" \
  -e OAUTH_CLIENTS="$oauth_clients" \
  -e SUITE=resolute \
  -e MIRROR=http://ports.ubuntu.com/ubuntu-ports \
  -e ISO_LABEL=UBUNTU_LIVE \
  -e PERSIST_SERIAL=ubuntu-persist \
  -e ISO_NAME="$iso_name" \
  "$image" /src/scripts/in-container.sh

echo
echo "Done: $dist_dir/$iso_name"
echo "Boot it with: ./run-qemu.sh"
