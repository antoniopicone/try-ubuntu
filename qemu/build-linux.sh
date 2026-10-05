#!/usr/bin/env bash
# Builds a QEMU for Linux desktops, for run-qemu.sh: qemu-system-aarch64 and
# qemu-system-x86_64, each with KVM (for ISOs of the computer's own
# architecture) and TCG (for the other's), a GTK window with OpenGL, and
# virtio-gpu-gl through VirGL: the guest's Mesa virgl driver ->
# virglrenderer -> the host's OpenGL. Plus what run-qemu.sh uses for the
# desktop: PulseAudio and ALSA (virtio-sound), 9p (the shared folder),
# qemu-vdagent (the clipboard, shared with the GTK window through the
# guest's spice-vdagent), a VNC server and the UEFI firmware of both
# architectures. A distribution's QEMU does the same when all of its
# packages are installed: this one needs no root and nothing installed.
#
# It's the same QEMU as the Macs' (sources.sh, pinned by sha256), without
# their patches (those are for Cocoa and HVF). It builds in a podman
# container of this computer's architecture (Containerfile: Ubuntu 22.04),
# without network: the sources are downloaded here first. The result, in
# dist/, for <arch> arm64 or amd64:
#
#   qemu-linux-<arch>/bin/{qemu-system-aarch64,qemu-system-x86_64,qemu-img}
#   qemu-linux-<arch>/lib/*.so             (virglrenderer and libslirp)
#   qemu-linux-<arch>/share/qemu/          (edk2 UEFI firmware, ROMs)
#   qemu-linux-<arch>.tar.gz               (what the releases ship)
#
# It runs where glibc is 2.35 or newer (Ubuntu 22.04, Debian 12, Fedora 36)
# and the desktop's libraries are there: GTK 3, Mesa (EGL, GBM), the
# PulseAudio client library and ALSA's. install.sh checks that it starts,
# and falls back to the distribution's QEMU.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: qemu/build.sh [--out DIR] [--cache DIR] [--keep-work]

  --out DIR     where the runtime and its tarball go (default: dist)
  --cache DIR   downloaded archives, kept between builds
                (default: dist/.cache/qemu)
  --keep-work   keep the build tree (default: removed on exit)
EOF
}

qemu_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
project_dir=$(dirname "$qemu_dir")
out_dir="$project_dir/dist"
cache_dir=""
keep_work=0
in_container=0
while (($#)); do
  case "$1" in
    --out)   out_dir=$2; shift 2 ;;
    --cache) cache_dir=$2; shift 2 ;;
    --keep-work) keep_work=1; shift ;;
    --in-container) in_container=1; shift ;;   # this script, in the builder
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

log() { printf '\033[1m[qemu] %s\033[0m\n' "$*"; }
die() { printf '\033[31m[qemu] error:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $(uname -s) == Linux ]] || die "this builds for Linux: run it there (on a Mac, qemu/build.sh)"
case "$(uname -m)" in
  x86_64)  arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *) die "unsupported CPU: $(uname -m)" ;;
esac
name=qemu-linux-$arch

# --- Pinned sources ---------------------------------------------------------

. "$qemu_dir/sources.sh"

slirp_version=4.9.4

# name  url  sha256  (the file is saved as the url's last component)
sources() {
  common_sources
  cat <<EOF
libslirp-v$slirp_version.tar.gz	https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v$slirp_version/libslirp-v$slirp_version.tar.gz	3998863b020aeda34bddc567097c6efba55a78cdf6eeee6bcd42c11ef23967da
EOF
}

# What a computer with a desktop has, and QEMU takes from it: the C
# library, GLib, GTK 3 with what it draws with, Mesa, the sound systems'
# client libraries. Anything else must be in lib/.
host_libs='^(ld-linux-.*|lib(c|m|dl|rt|pthread|gcc_s|z)|'
host_libs+='lib(glib|gobject|gio|gmodule)-2\.0|libpixman-1|'
host_libs+='lib(gtk|gdk)-3|libgdk_pixbuf-2\.0|libcairo|libcairo-gobject|libpango-1\.0|libpangocairo-1\.0|'
host_libs+='libharfbuzz|libatk-1\.0|libX11|libepoxy|libgbm|libdrm|libpulse|libasound)\.so(\.[0-9]+)*$'

# --- In the builder ---------------------------------------------------------

# /qemu is this directory, /cache the downloads, /work the build tree.
build_in_container() {
  # tar keeps the archives' owners and modes here: on the way out, the
  # build tree becomes one its owner outside can delete.
  trap 'chown -R 0:0 /work; chmod -R u+rwX /work' EXIT
  cache_dir=/cache
  src=/work/src
  deps=/work/deps
  tools=/work/tools
  mkdir -p "$src" "$deps" "$tools"

  tar -xzf "$cache_dir/meson-$meson_version.tar.gz" -C "$tools"
  tar -xzf "$cache_dir/pyyaml-$pyyaml_version.tar.gz" -C "$tools"
  meson=(python3 "$tools/meson-$meson_version/meson.py")
  export PYTHONPATH="$tools/pyyaml-$pyyaml_version/lib" PYTHONNOUSERSITE=1
  export PKG_CONFIG_PATH="$deps/lib/pkgconfig:$deps/share/pkgconfig"

  log "Building virglrenderer $virgl_version"
  tar -xzf "$cache_dir/virglrenderer-$virgl_version.tar.gz" -C "$src"
  virgl_src="$src/virglrenderer-$virgl_version"
  "${meson[@]}" setup "$virgl_src/build" "$virgl_src" \
    --prefix="$deps" --libdir=lib --buildtype=release --wrap-mode=nodownload \
    -Dplatforms=egl -Ddrm-renderers=[] -Dvenus=false -Dtests=false -Dvideo=false -Dtracing=none
  ninja -C "$virgl_src/build"
  "${meson[@]}" install -C "$virgl_src/build" --no-rebuild >/dev/null

  log "Building libslirp $slirp_version"
  tar -xzf "$cache_dir/libslirp-v$slirp_version.tar.gz" -C "$src"
  slirp_src="$src/libslirp-v$slirp_version"
  # The version comes from git, or from this file in a release's tarball
  printf '%s\n' "$slirp_version" > "$slirp_src/.tarball-version"
  "${meson[@]}" setup "$slirp_src/build" "$slirp_src" \
    --prefix="$deps" --libdir=lib --buildtype=release --wrap-mode=nodownload
  ninja -C "$slirp_src/build"
  "${meson[@]}" install -C "$slirp_src/build" --no-rebuild >/dev/null

  log "Installing spice-protocol $spice_protocol_version"
  tar -xJf "$cache_dir/spice-protocol-$spice_protocol_version.tar.xz" -C "$src"
  "${meson[@]}" setup "$src/spice-protocol-$spice_protocol_version/build" \
    "$src/spice-protocol-$spice_protocol_version" --prefix="$deps" >/dev/null
  "${meson[@]}" install -C "$src/spice-protocol-$spice_protocol_version/build" >/dev/null

  log "Building QEMU $qemu_version"
  tar -xzf "$cache_dir/qemu-$qemu_commit.tar.gz" -C "$src"
  qemu_src="$src/qemu-$qemu_commit"
  mkdir -p "$qemu_src/subprojects/keycodemapdb" "$qemu_src/subprojects/dtc"
  tar -xzf "$cache_dir/keycodemapdb-$keycodemap_commit.tar.gz" --strip-components=1 \
    -C "$qemu_src/subprojects/keycodemapdb"
  tar -xzf "$cache_dir/dtc-$dtc_commit.tar.gz" --strip-components=1 -C "$qemu_src/subprojects/dtc"
  cp "$cache_dir"/{setuptools,wheel,packaging,pip}-*.whl "$qemu_src/python/wheels/"
  # With TCG, the floating point tests want two more subprojects at
  # configure time (Berkeley's softfloat and testfloat): no tests here.
  sed -i "/subdir('fp')/d" "$qemu_src/tests/meson.build"

  mkdir "$qemu_src/build"
  (cd "$qemu_src/build" && ../configure \
    --prefix=/work/install \
    --target-list=aarch64-softmmu,x86_64-softmmu \
    --without-default-features \
    --enable-system --enable-tools \
    --enable-kvm --enable-tcg \
    --enable-gtk --enable-opengl --enable-virglrenderer \
    --enable-pixman --enable-slirp --enable-fdt=internal \
    --enable-pa --enable-alsa --enable-virtfs --enable-attr \
    --enable-spice-protocol --enable-vnc \
    --disable-debug-info --disable-werror --disable-download \
    --disable-containers)
  ninja -C "$qemu_src/build" qemu-system-aarch64 qemu-system-x86_64 qemu-img

  log "Assembling $name"
  rt="/work/$name"
  mkdir -p "$rt/bin" "$rt/lib" "$rt/share/qemu"
  install -m 0755 -s "$qemu_src"/build/{qemu-system-aarch64,qemu-system-x86_64,qemu-img} "$rt/bin/"
  # The ROMs of the devices run-qemu.sh uses, and SeaBIOS for -bios-less x86
  for rom in efi-virtio.rom vgabios-virtio.bin vgabios-stdvga.bin kvmvapic.bin \
             linuxboot_dma.bin bios-256k.bin; do
    install -m 0644 "$qemu_src/pc-bios/$rom" "$rt/share/qemu/"
  done
  for fd in edk2-aarch64-code.fd edk2-arm-vars.fd edk2-x86_64-code.fd edk2-i386-vars.fd; do
    bunzip2 -c "$qemu_src/pc-bios/$fd.bz2" > "$rt/share/qemu/$fd"
  done
  install -m 0644 "$qemu_src/pc-bios/edk2-licenses.txt" "$rt/share/qemu/"
  # The VNC server's keyboard layouts
  mkdir "$rt/share/qemu/keymaps"
  for keymap in "$qemu_src"/pc-bios/keymaps/*; do
    [[ $keymap == *.build ]] || install -m 0644 "$keymap" "$rt/share/qemu/keymaps/"
  done
  install -m 0755 -s "$deps/lib/libvirglrenderer.so.1" "$deps/lib/libslirp.so.0" "$rt/lib/"

  # Relocate: the bundled libraries are found from where QEMU is (RUNPATH),
  # and nothing else may come from outside what the host is known to have.
  images=("$rt"/bin/* "$rt"/lib/*)
  for image in "${images[@]}"; do
    if [[ $image == "$rt/lib/"* ]]; then
      patchelf --set-rpath '$ORIGIN' "$image"
    else
      patchelf --set-rpath '$ORIGIN/../lib' "$image"
    fi
  done

  log "Checking $name"
  for image in "${images[@]}"; do
    patchelf --print-needed "$image" | while read -r lib; do
      if [[ -f "$rt/lib/$lib" ]]; then
        path=$(ldd "$image" | awk -v lib="$lib" '$1 == lib {print $3}')
        [[ -n "$path" && $(realpath "$path") == "$rt/lib/$lib" ]] ||
          die "${image##*/} doesn't load $lib from the runtime"
      else
        [[ $lib =~ $host_libs ]] || die "${image##*/} needs $lib, which isn't bundled"
      fi
    done
  done
  "$rt/bin/qemu-img" --version >/dev/null || die "qemu-img doesn't run"
  for target in aarch64 x86_64; do
    q="$rt/bin/qemu-system-$target"
    "$q" --version | grep -q "version $qemu_version" || die "qemu-system-$target doesn't run"
    accels=$("$q" -accel help)
    grep -qx tcg <<<"$accels" || die "qemu-system-$target: no TCG"
    # KVM: for guests of this computer's architecture
    [[ $target != "$(uname -m)" ]] || grep -qx kvm <<<"$accels" || die "qemu-system-$target: no KVM"
    "$q" -display help | grep -qx gtk || die "qemu-system-$target: no GTK display"
    printf '%s\n' '{"execute":"qmp_capabilities"}' '{"execute":"quit"}' |
      "$q" -machine none -accel qtest -display none -vnc none -qmp stdio >/dev/null 2>&1 ||
      die "qemu-system-$target: no VNC server"
    devices=$("$q" -device help)
    gpu=virtio-gpu-gl-pci
    [[ $target == x86_64 ]] && gpu=virtio-vga-gl
    for d in "$gpu" virtio-gpu-pci virtio-balloon-pci virtio-net-pci virtio-rng-pci \
             virtio-scsi-pci scsi-cd virtio-blk-pci qemu-xhci usb-kbd usb-tablet \
             virtio-sound-pci virtio-9p-pci virtio-serial-pci virtserialport; do
      grep -q "name \"$d\"" <<<"$devices" || die "qemu-system-$target: no $d device"
    done
    audio=$("$q" -audiodev help)
    for a in pa alsa; do
      grep -qx "$a" <<<"$audio" || die "qemu-system-$target: no $a audio"
    done
    "$q" -machine none -chardev help | grep -qx '  *qemu-vdagent' ||
      die "qemu-system-$target: no qemu-vdagent"
    "$q" -machine none -accel qtest -netdev help | grep -qx user ||
      die "qemu-system-$target: no user networking (slirp)"
  done
}

if ((in_container)); then
  build_in_container
  exit 0
fi

# --- Checks -----------------------------------------------------------------

for tool in podman curl tar; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd -P)
[[ -n "$cache_dir" ]] || cache_dir="$out_dir/.cache/qemu"
mkdir -p "$cache_dir"
cache_dir=$(cd "$cache_dir" && pwd -P)

# --- Downloads --------------------------------------------------------------

fetch_all < <(sources)

# --- Build ------------------------------------------------------------------

work=$(mktemp -d "${TMPDIR:-/tmp}/try-ubuntu-qemu.XXXXXX")
cleanup() {
  if ((keep_work)); then echo "Build tree kept in $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

log "Builder image ($arch)"
image=try-ubuntu-qemu-builder
podman build -q --platform "linux/$arch" -t "$image" -f "$qemu_dir/Containerfile" "$qemu_dir" >/dev/null
# label=disable: the mounts, where SELinux confines containers
podman run --rm --network none --security-opt label=disable --platform "linux/$arch" \
  -v "$qemu_dir:/qemu:ro" -v "$cache_dir:/cache:ro" -v "$work:/work" \
  "$image" /qemu/build-linux.sh --in-container

rm -rf "${out_dir:?}/$name" "$out_dir/$name.tar.gz"
cp -a "$work/$name" "$out_dir/$name"
tar -czf "$out_dir/$name.tar.gz" -C "$out_dir" "$name"
log "Done: $out_dir/$name ($(du -sh "$out_dir/$name" | cut -f1)), $out_dir/$name.tar.gz"
