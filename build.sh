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
# Runs on macOS (Apple Silicon) and on Linux (x86 or arm64) through podman
# or docker, whichever is there (podman when both are; CONTAINER_ENGINE
# picks one): the build happens inside a privileged Ubuntu container of the
# ISO's architecture. The computer's own architecture is native (arm64 on
# Apple Silicon); the other runs emulated (qemu-user: in the podman machine
# or Docker Desktop's VM on a Mac, registered with binfmt_misc on Linux),
# which is slow. On Linux it needs root (sudo ./build.sh): the ISO step uses
# loop devices.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./build.sh [--arch arm|x86] [--hardware] [--xkb LAYOUT] [--oauth-clients FILE] [--clean]

  --arch ARCH    arm (arm64) or x86 (amd64); default: this computer's
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
# This computer's architecture, unless --arch says otherwise: the other one
# builds emulated
case $(uname -m) in
  x86_64|amd64) arch=amd64 ;;
  *) arch=arm64 ;;
esac
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

# Rootless podman can't create the rootfs's device nodes, nor loop-mount
# the btrfs image (on a Mac the podman machine is rootful). With docker,
# whose daemon is root, it's for what this script does itself: installing
# qemu-user, handing the ISO back to who ran it.
if [[ $(uname -s) == Linux ]] && (($(id -u) != 0)); then
  echo "On Linux the build needs root: sudo $0 ..." >&2
  exit 1
fi

# The container engine: podman or docker, whichever is installed
engine=${CONTAINER_ENGINE:-}
if [[ -z $engine ]]; then
  for engine in podman docker ""; do
    [[ -z $engine ]] || ! command -v "$engine" >/dev/null || break
  done
fi
case $engine in
  podman|docker)
    command -v "$engine" >/dev/null || { echo "$engine isn't installed" >&2; exit 1; } ;;
  "")
    if [[ $(uname -s) == Darwin ]]; then
      echo "podman or docker is required: brew install podman && podman machine init --now" >&2
    else
      echo "podman or docker is required: install one with your package manager" >&2
    fi
    exit 1 ;;
  *) echo "CONTAINER_ENGINE must be podman or docker" >&2; exit 64 ;;
esac
if [[ $engine == podman ]]; then
  if [[ $(uname -s) == Darwin ]] && ! podman machine inspect --format '{{.State}}' 2>/dev/null | grep -qx running; then
    echo "==> Starting the podman machine"
    podman machine start
  fi
elif ! docker info >/dev/null 2>&1; then
  if [[ $(uname -s) == Darwin ]]; then
    echo "docker isn't running: start Docker Desktop (or your docker VM) first" >&2
  else
    echo "docker isn't running: systemctl start docker" >&2
  fi
  exit 1
fi

if ((clean)); then
  "$engine" volume rm -f "$cache_volume" >/dev/null && echo "Build cache removed ($arch)."
  exit 0
fi

if [[ $engine == podman ]]; then
  host_arch=$(podman info --format '{{.Host.Arch}}')
else
  # The kernel's name for it: aarch64, x86_64
  case $(docker info --format '{{.Architecture}}') in
    x86_64|amd64) host_arch=amd64 ;;
    *) host_arch=arm64 ;;
  esac
fi
if [[ $host_arch != "$arch" ]]; then
  # qemu-user through binfmt_misc: the podman machine and Docker Desktop's
  # VM have it, a Linux host needs it installed (or the image's build fails
  # on the first RUN)
  emulator=qemu-aarch64
  [[ $arch == amd64 ]] && emulator=qemu-x86_64
  registered() { compgen -G "/proc/sys/fs/binfmt_misc/$emulator*" >/dev/null; }
  if [[ $(uname -s) == Linux ]] && ! registered; then
    echo "==> Installing qemu-user (to run $arch containers)"
    if command -v apt-get >/dev/null; then
      # qemu-user-static became qemu-user and qemu-user-binfmt (Debian 13, Ubuntu 25.04)
      apt-get update -qq
      if apt-cache show qemu-user-binfmt >/dev/null 2>&1; then apt-get install -y qemu-user-binfmt
      else apt-get install -y qemu-user-static; fi
    elif command -v dnf >/dev/null; then dnf install -y qemu-user-static
    elif command -v pacman >/dev/null; then
      pacman -S --needed --noconfirm qemu-user-static qemu-user-static-binfmt
    fi
    registered || systemctl restart systemd-binfmt.service || true
    if ! registered; then
      echo "Building $arch on $host_arch needs qemu-user registered with binfmt_misc:" >&2
      echo "install qemu-user-binfmt or qemu-user-static with your package manager" >&2
      exit 1
    fi
  fi
  echo "==> Building $arch on $host_arch: emulated, it takes a long time"
fi

echo "==> Builder image ($arch)"
# --platform, always: the local ubuntu:26.04 may be the other
# architecture's after a build of it.
# --network host, here and in builder: a bridge needs nft, which podman only
# recommends, and its traffic is dropped by a host firewall that doesn't
# forward (ufw), so the first apt-get resolves nothing.
"$engine" build -q --network host --platform "linux/$arch" -t "$image" -f "$project_dir/Containerfile" \
  "$project_dir" >/dev/null
if [[ $host_arch != "$arch" ]]; then
  # The ISO step runs natively (see below): the host's builder too
  "$engine" build -q --network host --platform "linux/$host_arch" -t "$(builder_image "$host_arch")" \
    -f "$project_dir/Containerfile" "$project_dir" >/dev/null
fi
"$engine" volume inspect "$cache_volume" >/dev/null 2>&1 \
  || "$engine" volume create "$cache_volume" >/dev/null

mkdir -p "$dist_dir"
# --privileged plus the host's /dev: the ISO step loop-mounts the btrfs image
# (to add the snapper snapshot), and loop devices are created on demand.
# ISO_LABEL is the live medium's label and PERSIST_SERIAL the serial of the
# persistent disk (run-qemu.sh --persist): btrfslive looks for both.
# The cache volume holds the rootfs, with device nodes (debootstrap writes
# to its /dev/null) and setuid files: podman 6 mounts named volumes nodev
# and nosuid unless told otherwise (docker doesn't, and has no such options).
cache_options=""
[[ $engine == podman ]] && cache_options=:dev,suid
# builder PLATFORM IMAGE STEPS...: the build steps in a builder container
builder() {
  local platform=$1 builder_image=$2; shift 2
  "$engine" run --rm --privileged --network host --platform "linux/$platform" \
    -v /dev:/dev \
    -v "$cache_volume:/cache$cache_options" \
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

# Under sudo, the ISO and dist/ go back to whoever ran it: run-qemu.sh
# keeps the VM's state there.
if [[ -n "${SUDO_UID:-}" ]]; then
  chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$dist_dir" "$dist_dir/$iso_name"
fi

echo
echo "Done: $dist_dir/$iso_name"
if ((hardware)); then
  echo "Write it to a USB stick with: ./install.sh --on-usb (or dd)"
else
  echo "Boot it with: ./run-qemu.sh$([[ $arch == "$host_arch" ]] || echo " --iso $dist_dir/$iso_name")"
fi
