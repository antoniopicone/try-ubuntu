#!/usr/bin/env bash
# Opens the live user's home, as kept on the persistent disk, in the Finder.
#
# The persistent disk (dist/persist.qcow2) isn't a filesystem of its own:
# it's the btrfs "sprout" of the seed image live/rootfs.btrfs on the ISO
# that created it (see the btrfslive initramfs script), and macOS can't read
# btrfs anyway. So, like build.sh, this works inside a privileged container
# of the podman machine: the ISO's seed goes on a loop device, the qcow2 on
# an nbd device, and the @home subvolume is mounted read-only and served
# over SMB on 127.0.0.1, which the Mac mounts and opens in the Finder.
# Ctrl-C unmounts everything.
#
# Read-only on purpose: the VM must be off (its disk would be changing
# under the mount), and nothing here can harm the disk.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./mount-home.sh [options]

  --iso PATH       the ISO the disk belongs to (default: dist/ubuntu-live-arm64.iso)
  --persist FILE   the persistent disk (default: dist/persist.qcow2)
  --at DIR         where to mount it on the Mac (default: dist/home)
  --port PORT      local port of the SMB server (default: 44545)
  --user NAME      whose home (default: the user made in the welcome, else
                   the image's own "ubuntu")
  --all            the whole /home, not only one user's home
EOF
}

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
iso="$project_dir/dist/ubuntu-live-arm64.iso"
persist="$project_dir/dist/persist.qcow2"
mnt="$project_dir/dist/home"
port=44545
all=0
user=""
image=try-ubuntu-mount
name=try-ubuntu-home
while (($#)); do
  case "$1" in
    --iso) iso=$2; shift 2 ;;
    --persist) persist=$2; shift 2 ;;
    --at) mnt=$2; shift 2 ;;
    --port) port=$2; shift 2 ;;
    --user) user=$2; shift 2 ;;
    --all) all=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

[[ $(uname -s) == Darwin ]] || { echo "This is for macOS (on Linux, mount the disk directly)." >&2; exit 1; }
[[ -f "$iso" ]] || { echo "ISO not found: $iso" >&2; exit 1; }
[[ -f "$persist" ]] || { echo "Persistent disk not found: $persist" >&2; exit 1; }
iso=$(cd "$(dirname "$iso")" && pwd -P)/$(basename "$iso")
persist=$(cd "$(dirname "$persist")" && pwd -P)/$(basename "$persist")
if pgrep -qf "file=$persist"; then
  echo "The VM using $persist is running: shut it down first." >&2
  exit 1
fi
# The disk extends the seed of one ISO only (run-qemu.sh records which)
iso_id=$(cut -d' ' -f1 "$iso.sha256" 2>/dev/null || true)
[[ -n "$iso_id" ]] || iso_id=$(stat -f '%z-%m' "$iso")
disk_id=$(cat "$persist.iso" 2>/dev/null || true)
if [[ -n "$disk_id" && "$disk_id" != "$iso_id" ]]; then
  echo "$persist was made by another ISO than $iso: pass that one with --iso." >&2
  exit 1
fi

command -v podman >/dev/null || {
  echo "podman is required: brew install podman && podman machine init --now" >&2
  exit 1
}
if ! podman machine inspect --format '{{.State}}' 2>/dev/null | grep -qx running; then
  echo "==> Starting the podman machine"
  podman machine start
fi
# Kernel modules come from the machine, not from the container
podman machine ssh "sudo modprobe -a nbd isofs btrfs" >/dev/null

echo "==> Mount image"
podman build -q -t "$image" -f - "$project_dir" >/dev/null <<'EOF'
FROM docker.io/library/ubuntu:26.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      btrfs-progs qemu-utils samba util-linux && rm -rf /var/lib/apt/lists/*
EOF

# What runs in the container: the mounts, then smbd until stopped.
inner=$(cat <<'EOF'
set -eu
nbd="" iso_loop="" seed=""
cleanup() {
  # Ignored, not reset: stopping smbd signals its whole process group, us too
  trap '' TERM INT
  trap - EXIT
  set +e  # undo all there is, whatever fails
  [ -n "${smbd:-}" ] && kill "$smbd" 2>/dev/null && wait "$smbd" 2>/dev/null
  mountpoint -q /mnt/home && umount /mnt/home
  # btrfs keeps scanned devices registered: forget them, or the loops stay
  [ -n "$nbd" ] && { btrfs device scan --forget "$nbd"; qemu-nbd -d "$nbd" >/dev/null; }
  [ -n "$seed" ] && { btrfs device scan --forget "$seed"; losetup -d "$seed"; }
  # The seed's loop lets go of the ISO a moment later
  for i in $(seq 20); do mountpoint -q /mnt/iso || break; umount /mnt/iso 2>/dev/null || sleep 0.5; done
  [ -n "$iso_loop" ] && losetup -d "$iso_loop"
  exit 0
}
trap cleanup EXIT TERM INT

mkdir -p /mnt/iso /mnt/home
iso_loop=$(losetup -r -f --show /live.iso)
mount -t iso9660 -o ro "$iso_loop" /mnt/iso
seed=$(losetup -r -f --show /mnt/iso/live/rootfs.btrfs)
btrfs device scan "$seed" >/dev/null

for dev in /sys/block/nbd*; do
  if [ ! -e "$dev/pid" ]; then nbd=/dev/${dev##*/}; break; fi
done
[ -n "$nbd" ] || { echo "no free nbd device" >&2; exit 1; }
qemu-nbd --read-only --format=qcow2 -c "$nbd" /persist.qcow2
# Connected once it has a size (its pid shows up earlier)
for i in $(seq 100); do [ "$(cat "/sys/block/${nbd#/dev/}/size")" != 0 ] && break; sleep 0.1; done
btrfs device scan "$nbd" >/dev/null
# A session that wasn't shut down cleanly leaves a log to replay, which a
# read-only device can't take: skip it (the last seconds before the crash)
mount -t btrfs -o ro,subvol=@home "$nbd" /mnt/home 2>/dev/null \
  || mount -t btrfs -o ro,rescue=nologreplay,subvol=@home "$nbd" /mnt/home \
  || { echo "can't mount the disk: is it from this ISO?" >&2; exit 1; }

# The welcome adds the user's own account next to the image's "ubuntu"
share=/mnt/home user=$USER_NAME
if [ "$ALL" = 0 ] && [ -z "$user" ]; then
  users=$(find /mnt/home -mindepth 1 -maxdepth 1 -type d ! -name ubuntu -printf '%f\n')
  count=$(echo "$users" | grep -c . || true)
  if [ "$count" = 0 ]; then user=ubuntu; elif [ "$count" = 1 ]; then user=$users; fi
fi
if [ -n "$user" ]; then
  [ -d "/mnt/home/$user" ] || { echo "no home for $user in:" $(ls /mnt/home) >&2; exit 1; }
  share=/mnt/home/$user
fi

# A uid no live user has, not to show up as the owner of their files
useradd -M -u 60000 -s /usr/sbin/nologin mac
printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" | smbpasswd -s -a mac >/dev/null
cat > /etc/samba/smb.conf <<CONF
[global]
  server role = standalone server
  map to guest = never
  disable netbios = yes
  smb ports = 445
  load printers = no
  printcap name = /dev/null
  disable spoolss = yes
  log level = 1
[home]
  path = $share
  read only = yes
  valid users = mac
  # The files belong to the live user's uid: read them all
  force user = root
CONF
smbd --foreground --no-process-group --debug-stdout &
smbd=$!
for i in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/445) 2>/dev/null && break; sleep 0.2; done
echo "READY ${user:-/home}"
wait "$smbd"
EOF
)

password=$(openssl rand -hex 16)
podman rm -f "$name" >/dev/null 2>&1 || true
podman run -d --name "$name" --privileged \
  -v /dev:/dev \
  -v "$iso:/live.iso:ro" \
  -v "$persist:/persist.qcow2:ro" \
  -p "127.0.0.1:$port:445" \
  -e PASSWORD="$password" -e ALL="$all" -e USER_NAME="$user" \
  "$image" bash -c "$inner" >/dev/null

stop() {
  trap - EXIT INT TERM
  echo
  echo "==> Unmounting"
  if mount | grep -q " on $mnt "; then
    umount "$mnt" 2>/dev/null || diskutil unmount force "$mnt" >/dev/null || true
  fi
  rmdir "$mnt" 2>/dev/null || true
  podman stop -t 30 "$name" >/dev/null 2>&1 || true
  podman rm -f "$name" >/dev/null 2>&1 || true
}
trap stop EXIT INT TERM

echo "==> Mounting the persistent disk"
ready=""
for i in $(seq 150); do
  ready=$(podman logs "$name" 2>/dev/null | sed -n 's/^READY //p') || true
  [[ -n "$ready" ]] && break
  if [[ $(podman inspect -f '{{.State.Running}}' "$name" 2>/dev/null) != true ]]; then
    podman logs "$name" >&2 || true
    echo "The disk could not be mounted." >&2
    exit 1
  fi
  sleep 0.2
done
[[ -n "$ready" ]] || { podman logs "$name" >&2; echo "Timed out." >&2; exit 1; }

mkdir -p "$mnt"
mount_smbfs -N "//mac:$password@127.0.0.1:$port/home" "$mnt"
open "$mnt"
echo "Home of ${ready} (read-only) in $mnt"
echo "Ctrl-C to unmount."
while [[ $(podman inspect -f '{{.State.Running}}' "$name" 2>/dev/null) == true ]]; do sleep 2; done
