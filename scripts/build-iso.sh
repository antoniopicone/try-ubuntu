#!/usr/bin/env bash
# Consumes $ROOTFS (it is moved into the subvolume layout) and turns it into
# a btrfs seed image with the subvolumes @, @home, @var and @snapshots (plus
# snapper snapshot #1, "the image as shipped"), then wraps it with the
# kernel, initramfs and the Limine bootloader (arm64 UEFI) into a hybrid
# ISO: bootable as a CD-ROM (El Torito EFI) and, written raw to a USB stick,
# through its appended EFI system partition.
set -euo pipefail

: "${ROOTFS:?}" "${WORK:?}" "${ISO_OUT:?}" "${ISO_LABEL:?}"
: "${BTRFS_COMPRESS:=zstd:15}"

# Limine, pinned: the files are checked individually (the release archive is
# generated on the fly by the forge, its own hash is not stable).
LIMINE_VERSION=11.2.1
# Codeberg first, the GitHub mirror when Codeberg is down (same files).
LIMINE_URLS=(
  "https://codeberg.org/Limine/Limine/archive/v$LIMINE_VERSION-binary.tar.gz"
  "https://github.com/limine-bootloader/limine/archive/refs/tags/v$LIMINE_VERSION-binary.tar.gz"
)
LIMINE_BOOTAA64_SHA256=d06b255a8affd87f16bc7bdfce30a0a0ba3b883b8b0dae8146c81d6a56ed649d

layout="$WORK/btrfs-layout"
iso_tree="$WORK/iso"
mnt="$WORK/mnt"
rm -rf "$layout" "$iso_tree"
mkdir -p "$layout" "$iso_tree/live" "$iso_tree/boot/limine" "$mnt"

kernel=$(ls "$ROOTFS"/boot/vmlinuz-* | sort -V | tail -1)
initrd="$ROOTFS/boot/initrd.img-${kernel##*/vmlinuz-}"
# Ubuntu's arm64 vmlinuz is an EFI zboot image (a PE wrapping a compressed
# kernel); Limine's Linux protocol needs the raw arm64 Image inside it.
python3 "$(dirname "$0")/unzboot.py" "$kernel" "$iso_tree/live/Image"
cp "$initrd" "$iso_tree/live/initrd"
# Limine boots them from the ISO: the copies in the root filesystem would
# only double their size in the image.
rm -f "$ROOTFS"/boot/{vmlinuz,initrd.img,System.map,config}-* "$ROOTFS"/boot/{vmlinuz,initrd.img}{,.old}
# The desktop's wallpaper (picked by build-rootfs.sh), dark variant.
limine_wallpaper=$(ls "$WORK"/limine-wallpaper.*)
limine_wallpaper_name=wallpaper.${limine_wallpaper##*.}
cp "$limine_wallpaper" "$iso_tree/boot/limine/$limine_wallpaper_name"
menu_title="Ubuntu"

echo "==> Laying out the subvolumes"
# Flat layout: every subvolume is a child of the top level (id 5), so @ can
# be snapshotted/rolled back without dragging /home or /var along.
mv "$ROOTFS" "$layout/@"
mv "$layout/@/home" "$layout/@home"
mv "$layout/@/var"  "$layout/@var"
mkdir -p "$layout/@snapshots" "$layout/@/home" "$layout/@/var" "$layout/@/.snapshots"
chmod 0755 "$layout/@/home" "$layout/@/var"
chmod 0750 "$layout/@snapshots"

echo "==> Creating the btrfs image ($BTRFS_COMPRESS)"
img="$iso_tree/live/rootfs.btrfs"
truncate -s 16G "$img"
mkfs.btrfs -q -f -L ubuntu-live-root -m single -d single \
  --rootdir "$layout" --compress "$BTRFS_COMPRESS" \
  --subvol rw:@ --subvol rw:@home --subvol rw:@var --subvol rw:@snapshots \
  "$img"

echo "==> Snapper snapshot #1 and shrinking"
# A snapshot shares all its extents with @: it costs only metadata, and it
# needs a mounted filesystem (hence the loop device).
loopdev=$(losetup -f --show "$img")
cleanup_loop() { umount "$mnt" 2>/dev/null || true; losetup -d "$loopdev" 2>/dev/null || true; }
trap cleanup_loop EXIT
mount -o compress=zstd:15 "$loopdev" "$mnt"
mkdir -p "$mnt/@snapshots/1"
btrfs subvolume snapshot -r "$mnt/@" "$mnt/@snapshots/1/snapshot" >/dev/null
build_date=$(date -u '+%Y-%m-%d %H:%M:%S')
cat > "$mnt/@snapshots/1/info.xml" <<EOF
<?xml version="1.0"?>
<snapshot>
  <type>single</type>
  <num>1</num>
  <date>$build_date</date>
  <description>Live image as built</description>
  <cleanup></cleanup>
</snapshot>
EOF
chmod 0644 "$mnt/@snapshots/1/info.xml"
sync
# Shrink to the minimum (plus a little slack), then cut the file there.
min_size=$(btrfs inspect-internal min-dev-size "$mnt" | awk '{ print $1 }')
new_size=$(( (min_size / 1048576 + 64) * 1048576 ))
btrfs filesystem resize "$new_size" "$mnt" >/dev/null
umount "$mnt"
losetup -d "$loopdev"
trap - EXIT
truncate -s "$new_size" "$img"
btrfstune -S 1 "$img"
btrfs inspect-internal dump-super "$img" | grep -E '^(label|flags|total_bytes)'
btrfs inspect-internal dump-tree -t root "$img" | grep -oE 'ref .* name [@a-z]+' | grep -oE '[@a-z]+$' | sort -u | xargs echo "subvolumes:"

echo "==> Limine $LIMINE_VERSION (arm64 UEFI)"
limine_dir="$WORK/limine"
limine_tgz="$WORK/limine.tar.gz"
for url in "${LIMINE_URLS[@]}"; do
  curl -fsSL --retry 3 -o "$limine_tgz" "$url" && break
  echo "    $url unavailable, trying the next source"
  rm -f "$limine_tgz"
done
[[ -f $limine_tgz ]] || { echo "Limine $LIMINE_VERSION: no source reachable" >&2; exit 1; }
rm -rf "$limine_dir"
mkdir -p "$limine_dir"
tar xzf "$limine_tgz" -C "$limine_dir" --strip-components=1
rm -f "$limine_tgz"
echo "$LIMINE_BOOTAA64_SHA256  $limine_dir/BOOTAA64.EFI" | sha256sum -c --quiet

# Limine reads /boot/limine/limine.conf from the ISO 9660 volume, where the
# kernel and initramfs are too.
cat > "$iso_tree/boot/limine/limine.conf" <<EOF
# Limine menu of the $menu_title live ISO.
timeout: 5
default_entry: 1
interface_branding: $menu_title  (live, btrfs)
interface_branding_colour: 7
wallpaper: boot():/boot/limine/$limine_wallpaper_name
wallpaper_style: stretched
term_background: 40000000
term_foreground: ffffff
term_palette: 241f31;c01c28;2ec27e;f5c211;3584e4;9141ac;0ab9dc;deddda
term_palette_bright: 5e5c64;ed333b;57e389;f8e45c;62a0ea;c061cb;4fd2fd;ffffff
term_margin: 64

# With a serial console on the command line Plymouth falls back to text
# unless told to ignore it; console=tty0 last keeps systemd's output on the
# screen (behind the splash), kernel messages still reach the serial port.
\${LIVE}=boot=btrfslive console=ttyAMA0 console=tty0
\${SPLASH}=quiet splash loglevel=3 plymouth.ignore-serial-consoles

/$menu_title
    comment: Live session on btrfs. Changes go to RAM, or to the persistent disk if one is attached.
    protocol: linux
    path: boot():/live/Image
    module_path: boot():/live/initrd
    cmdline: \${LIVE} \${SPLASH}

/+Snapper snapshots
    comment: Boot a writable copy of a snapshot; the current system (@) is left untouched.

//Choose at boot (every snapshot, persistent disk included)
    comment: Lists the snapshots on the console and asks for a number.
    protocol: linux
    path: boot():/live/Image
    module_path: boot():/live/initrd
    cmdline: \${LIVE} btrfslive.snapshot=ask

//#1  Live image as built  ($build_date UTC)
    protocol: linux
    path: boot():/live/Image
    module_path: boot():/live/initrd
    cmdline: \${LIVE} \${SPLASH} btrfslive.snapshot=1

/Troubleshooting

//Verbose boot
    protocol: linux
    path: boot():/live/Image
    module_path: boot():/live/initrd
    cmdline: \${LIVE}

//Text console only
    protocol: linux
    path: boot():/live/Image
    module_path: boot():/live/initrd
    cmdline: \${LIVE} systemd.unit=multi-user.target

//RAM only (ignore the persistent disk)
    protocol: linux
    path: boot():/live/Image
    module_path: boot():/live/initrd
    cmdline: \${LIVE} \${SPLASH} btrfslive.persist=no
EOF

efi_img="$WORK/efi.img"
rm -f "$efi_img"
mkfs.vfat -C -n "${ISO_LABEL%_LIVE}_EFI" "$efi_img" 4096 >/dev/null
mmd -i "$efi_img" ::/EFI ::/EFI/BOOT
mcopy -i "$efi_img" "$limine_dir/BOOTAA64.EFI" ::/EFI/BOOT/BOOTAA64.EFI

echo "==> Writing $ISO_OUT"
mkdir -p "$(dirname "$ISO_OUT")"
rm -f "$ISO_OUT"
xorriso -as mkisofs -r -J -joliet-long -iso-level 3 -V "$ISO_LABEL" \
  -partition_offset 16 \
  -append_partition 2 0xef "$efi_img" -appended_part_as_gpt \
  -e --interval:appended_partition_2:all:: -no-emul-boot \
  -o "$ISO_OUT" "$iso_tree" 2>&1 | grep -vE '^xorriso : UPDATE' || true
[[ -s "$ISO_OUT" ]] || { echo "ISO was not written" >&2; exit 1; }
(cd "$(dirname "$ISO_OUT")" && sha256sum "$(basename "$ISO_OUT")" > "$(basename "$ISO_OUT").sha256")
ls -lh "$ISO_OUT"
