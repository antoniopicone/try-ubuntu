#!/usr/bin/env bash
# Builds a self-contained QEMU for Apple Silicon Macs, for run-qemu.sh:
# qemu-system-aarch64 with HVF (and its nested virtualization), a Cocoa
# window with OpenGL, and virtio-gpu-gl through VirGL: the guest's Mesa
# virgl driver -> virglrenderer -> ANGLE (OpenGL ES) -> Metal. Homebrew's
# qemu has no virglrenderer and its Cocoa display has no OpenGL, so the
# guest can only render in software there.
#
# Adapted from Try Omarchy (https://github.com/omacom/try-omarchy,
# macos/build-qemu-gpu-runtime.sh, MIT): the same pinned QEMU, VirGL and
# ANGLE, and the patches in patches/ (see patches/README.md), without the
# app-specific parts (USB passthrough, pinch zoom...). On top of that, what
# run-qemu.sh uses for the desktop: CoreAudio (virtio-sound), 9p (the
# shared folder) and qemu-vdagent (the clipboard, shared with the Cocoa
# window through the guest's spice-vdagent).
#
# Every download is pinned by sha256. The libraries come from Homebrew's
# arm64_sequoia bottles, fetched directly from ghcr.io (Homebrew itself is
# not used, nor anything installed on the build machine besides Xcode's
# command line tools, python3 and pkg-config). The result, in dist/:
#
#   qemu-macos-arm64/bin/{qemu-system-aarch64,qemu-img}
#   qemu-macos-arm64/lib/*.dylib           (relocated, ad-hoc signed)
#   qemu-macos-arm64/share/qemu/           (edk2 UEFI firmware, virtio ROM)
#   qemu-macos-arm64.tar.gz                (what the releases ship)
#
# It runs on macOS 15 or newer; nested virtualization needs macOS 26 and an
# M3 or newer.
#
# On Linux this runs build-linux.sh instead: the same QEMU for Linux
# desktops (dist/qemu-linux-<arch>), built in a podman container.
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
[[ $(uname -s) != Linux ]] || exec "$qemu_dir/build-linux.sh" "$@"
out_dir="$project_dir/dist"
cache_dir=""
keep_work=0
while (($#)); do
  case "$1" in
    --out)   out_dir=$2; shift 2 ;;
    --cache) cache_dir=$2; shift 2 ;;
    --keep-work) keep_work=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd -P)
[[ -n "$cache_dir" ]] || cache_dir="$out_dir/.cache/qemu"
mkdir -p "$cache_dir"

name=qemu-macos-arm64
macos_min=15.0

log() { printf '\033[1m[qemu] %s\033[0m\n' "$*"; }
die() { printf '\033[31m[qemu] error:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Pinned sources ---------------------------------------------------------

# QEMU, virglrenderer, spice-protocol and the build tools: what the build
# for Linux uses too
. "$qemu_dir/sources.sh"

# virglrenderer gets startergo's macOS patches (tap v1.0.42) and is built
# here for macOS 15 (the tap's bottle needs 26); ANGLE and libepoxy bottles
# from startergo's taps.
virgl_tap_version=1.0.42
angle_version=1.0.16
epoxy_version=1.0.5

ninja_version=1.13.0

# name  url  sha256  (the file is saved as the url's last component)
sources() {
  common_sources
  cat <<EOF
homebrew-virglrenderer-$virgl_tap_version.tar.gz	https://codeload.github.com/startergo/homebrew-virglrenderer/tar.gz/refs/tags/v$virgl_tap_version	950273fbba46905b6112ee2bd0598c1da706c25319a7347058cbc52f04ba96dd
angle-$angle_version.arm64_sequoia.bottle.tar.gz	https://github.com/startergo/homebrew-angle/releases/download/v$angle_version/angle-$angle_version.arm64_sequoia.bottle.tar.gz	29fe2175b157a65f12879f9a12b5c8f94d0a76fafdf41ff009a2fdb4e9df525c
libepoxy-$epoxy_version.arm64_sequoia.bottle.tar.gz	https://github.com/startergo/homebrew-libepoxy/releases/download/v$epoxy_version/libepoxy-$epoxy_version.arm64_sequoia.bottle.tar.gz	109384a1d37edf207a9b9f3d8950710c00767635b3c7ff295e3af83611876ef2
ninja-$ninja_version-py3-none-macosx_10_9_universal2.whl	https://files.pythonhosted.org/packages/3c/74/d02409ed2aa865e051b7edda22ad416a39d81a84980f544f8de717cab133/ninja-$ninja_version-py3-none-macosx_10_9_universal2.whl	fa2a8bfc62e31b08f83127d1613d10821775a0eb334197154c4d6067b7068ff1
EOF
}

# Homebrew bottles (arm64_sequoia, i.e. built for macOS 15):
# formula  version  root in the archive  sha256 (= the ghcr.io blob)
bottles() {
  cat <<'EOF'
glib	2.88.3	glib/2.88.3	ca168ac34920f6ee13187d8e88af7d55c50b582fa78a5511e15fe9dd875e8b40
gettext	1.0	gettext/1.0	dde3cd0db0d7549fadf762b901f8c548dae99e3c592a6e6d41f60e1436253e5e
pcre2	10.47_1	pcre2/10.47_1	bef2e718b92e5e819a51723157e60eceb76acc4efb0894a10c315cd36abca13c
pixman	0.46.4	pixman/0.46.4	86f5fc013d2b22bbe41c1c14661287bf8e8e4c3ac95cd05b08b886d24918fe34
libslirp	4.9.4	libslirp/4.9.4	78dc33e108213bceb8f4b8a9d0293c0ff578a806ace4dfc4199af8c9714a2ffe
EOF
}

# In order: each may depend on the ones before it.
patches=(
  qemu-texture-borrowing-11.1.patch
  qemu-gpu-spike-resolution-fix.patch
  qemu-cocoa-dynamic-display.patch
  qemu-darwin-strchrnul-compat.patch
  qemu-hvf-free-page-reclaim.patch
  qemu-hvf-mapped-sections.patch
  qemu-darwin-gpu-fence-poll.patch
)

# startergo's virglrenderer patches, as the tap's formula applies them.
virgl_patches=(
  virglrenderer-debug-init-logging.patch
  virglrenderer-default-debug-log.patch
  virglrenderer-macos-unified.patch
  virglrenderer-venus-metal-func-ptrs.patch
  virglrenderer-gallium-endian.patch
  virglrenderer-macos-a8-swizzle.patch
  virglrenderer-corefoundation-link.patch
  virglrenderer-a8-shader-swizzle.patch
  virglrenderer-a8-shader-swizzle-texture.patch
  virglrenderer-a8-unpack-alignment.patch
  virglrenderer-bgra-upload-swizzle-core.patch
  virglrenderer-msaa-assertion-fix.patch
  virglrenderer-ignore-surface0-clear.patch
  virglrenderer-venus-errno-debug.patch
  virglrenderer-macos-profile-forcing.patch
  virglrenderer-macos-egl-profile.patch
  virglrenderer-texture-swizzle-core.patch
  virglrenderer-bgra-unified.patch
  virglrenderer-core-profile-frag-datalocation.patch
  virglrenderer-macos-core-profile-fixes.patch
  virglrenderer-gles-dual-source-output.patch
)

# --- Checks -----------------------------------------------------------------

[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || die "this builds for Apple Silicon Macs: run it on one"
macos_major=$(sw_vers -productVersion | cut -d. -f1)
((macos_major >= 15)) || die "macOS 15 or newer is needed"
for tool in cc curl shasum tar python3 pkg-config install_name_tool otool codesign bunzip2 ditto; do
  command -v "$tool" >/dev/null || die "$tool not found (Xcode command line tools: xcode-select --install; pkg-config: brew install pkgconf)"
done

# --- Downloads --------------------------------------------------------------

fetch_all < <(sources)

# Bottles are ghcr.io blobs: an anonymous token per formula.
while IFS=$'\t' read -r formula version root sha; do
  file="$formula-$version.arm64_sequoia.bottle.tar.gz"
  [[ -f "$cache_dir/$file" && $(sha256 "$cache_dir/$file") == "$sha" ]] && continue
  token=$(curl -fsS --proto '=https' --retry 3 \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/$formula:pull" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])') ||
    die "can't get a ghcr.io token for $formula"
  fetch "$file" "$sha" -H "Authorization: Bearer $token" \
    "https://ghcr.io/v2/homebrew/core/$formula/blobs/sha256:$sha"
done < <(bottles)

# --- Build tree -------------------------------------------------------------

work=$(mktemp -d "${TMPDIR:-/tmp}/try-ubuntu-qemu.XXXXXX")
cleanup() {
  if ((keep_work)); then echo "Build tree kept in $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

src="$work/src"
deps="$work/deps"
tools="$work/tools"
mkdir -p "$src" "$deps" "$tools"

tar -xzf "$cache_dir/meson-$meson_version.tar.gz" -C "$tools"
tar -xzf "$cache_dir/pyyaml-$pyyaml_version.tar.gz" -C "$tools"
ditto -x -k "$cache_dir/ninja-$ninja_version-py3-none-macosx_10_9_universal2.whl" "$tools"
meson=(python3 "$tools/meson-$meson_version/meson.py")
ninja="$tools/ninja-$ninja_version.data/scripts/ninja"
chmod +x "$ninja"
export PATH="$(dirname "$ninja"):$PATH"
export PYTHONPATH="$tools/pyyaml-$pyyaml_version/lib" PYTHONNOUSERSITE=1

tar -xzf "$cache_dir/angle-$angle_version.arm64_sequoia.bottle.tar.gz" -C "$deps"
tar -xzf "$cache_dir/libepoxy-$epoxy_version.arm64_sequoia.bottle.tar.gz" -C "$deps"
while IFS=$'\t' read -r formula version root sha; do
  tar -xzf "$cache_dir/$formula-$version.arm64_sequoia.bottle.tar.gz" -C "$deps"
done < <(bottles)

angle="$deps/angle/$angle_version"
epoxy="$deps/libepoxy/$epoxy_version"
virgl="$deps/virglrenderer/$virgl_version"
dep() { printf '%s/%s\n' "$deps" "$(bottles | awk -v f="$1" '$1 == f {print $3}')"; }
glib=$(dep glib) gettext=$(dep gettext) pcre2=$(dep pcre2) pixman=$(dep pixman) slirp=$(dep libslirp)

# Bottles' .pc files carry Homebrew's relocation placeholders: point them at
# the extracted trees, so nothing from the host's Homebrew gets in.
sed -i '' "s|@@HOMEBREW_CELLAR@@/libepoxy/$epoxy_version|$epoxy|g" "$epoxy"/lib/pkgconfig/*.pc
sed -i '' "s|^prefix=/opt/homebrew$|prefix=$angle|" "$angle"/lib/pkgconfig/*.pc
for d in "$glib" "$pcre2" "$pixman" "$slirp"; do
  sed -i '' -e "s|@@HOMEBREW_CELLAR@@/${d#"$deps"/}|$d|g" \
            -e "s|@@HOMEBREW_PREFIX@@/opt/gettext|$gettext|g" "$d"/lib/pkgconfig/*.pc
done

pc_dirs=""
for d in "$virgl" "$epoxy" "$angle" "$glib" "$pixman" "$slirp" "$pcre2"; do
  pc_dirs+="${pc_dirs:+:}$d/lib/pkgconfig"
done
lib_dirs=""
for d in "$virgl" "$epoxy" "$angle" "$glib" "$pixman" "$slirp" "$pcre2" "$gettext"; do
  lib_dirs+="${lib_dirs:+:}$d/lib"
done
export PKG_CONFIG_PATH="" PKG_CONFIG_LIBDIR="$pc_dirs"
export DYLD_FALLBACK_LIBRARY_PATH="$lib_dirs"
export MACOSX_DEPLOYMENT_TARGET=$macos_min
# -Werror=unguarded-availability-new: no API newer than macOS 15 sneaks in.
min_flags="-mmacosx-version-min=$macos_min -Werror=unguarded-availability-new"

# --- virglrenderer ----------------------------------------------------------

log "Building virglrenderer $virgl_version"
tar -xzf "$cache_dir/virglrenderer-$virgl_version.tar.gz" -C "$src"
tar -xzf "$cache_dir/homebrew-virglrenderer-$virgl_tap_version.tar.gz" -C "$src"
virgl_src="$src/virglrenderer-$virgl_version"
for p in "${virgl_patches[@]}"; do
  patch -s -d "$virgl_src" -p1 -f -i "$src/homebrew-virglrenderer-$virgl_tap_version/patches/$p"
done
CFLAGS="-I$angle/include $min_flags" OBJCFLAGS="$min_flags" \
LDFLAGS="-mmacosx-version-min=$macos_min -Wl,-headerpad_max_install_names" \
  "${meson[@]}" setup "$virgl_src/build" "$virgl_src" \
    --prefix="$virgl" --libdir=lib --buildtype=release --wrap-mode=nodownload \
    -Ddrm-renderers=[] -Dvenus=true -Dtests=false -Dvideo=false -Dtracing=none
"$ninja" -C "$virgl_src/build"
"${meson[@]}" install -C "$virgl_src/build" --no-rebuild >/dev/null

# --- spice-protocol ---------------------------------------------------------

log "Installing spice-protocol $spice_protocol_version"
spice_protocol="$deps/spice-protocol"
tar -xJf "$cache_dir/spice-protocol-$spice_protocol_version.tar.xz" -C "$src"
"${meson[@]}" setup "$src/spice-protocol-$spice_protocol_version/build" \
  "$src/spice-protocol-$spice_protocol_version" --prefix="$spice_protocol" >/dev/null
"${meson[@]}" install -C "$src/spice-protocol-$spice_protocol_version/build" >/dev/null
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR:$spice_protocol/share/pkgconfig"

# --- QEMU -------------------------------------------------------------------

log "Building QEMU $qemu_version"
tar -xzf "$cache_dir/qemu-$qemu_commit.tar.gz" -C "$src"
qemu_src="$src/qemu-$qemu_commit"
mkdir -p "$qemu_src/subprojects/keycodemapdb" "$qemu_src/subprojects/dtc"
tar -xzf "$cache_dir/keycodemapdb-$keycodemap_commit.tar.gz" --strip-components=1 \
  -C "$qemu_src/subprojects/keycodemapdb"
tar -xzf "$cache_dir/dtc-$dtc_commit.tar.gz" --strip-components=1 -C "$qemu_src/subprojects/dtc"
cp "$cache_dir"/{setuptools,wheel,packaging,pip}-*.whl "$qemu_src/python/wheels/"
for p in "${patches[@]}"; do
  patch -s -d "$qemu_src" -p1 -f -i "$qemu_dir/patches/$p"
done

# HVF only (no TCG): these binaries only run on Apple Silicon.
mkdir "$qemu_src/build"
(cd "$qemu_src/build" && ../configure \
  --prefix="$work/install" \
  --target-list=aarch64-softmmu \
  --without-default-features \
  --enable-system --enable-tools \
  --enable-hvf --disable-tcg \
  --enable-cocoa --enable-opengl --enable-virglrenderer \
  --enable-pixman --enable-slirp --enable-fdt=internal \
  --enable-coreaudio --enable-virtfs --enable-spice-protocol \
  --disable-debug-info --disable-werror --disable-download \
  --disable-containers --container-command=false \
  --extra-cflags="$min_flags" \
  --extra-ldflags="-mmacosx-version-min=$macos_min -Wl,-headerpad_max_install_names" \
  --ninja="$ninja")
# strchrnul is macOS 15.4+: the patch makes it a weak import, configure
# must not have picked it up as always available.
! grep -Eq '^#define HAVE_STRCHRNUL' "$qemu_src/build/config-host.h" ||
  die "configure enabled strchrnul, which macOS 15.0 doesn't have"
"$ninja" -C "$qemu_src/build" qemu-system-aarch64 qemu-img

# --- Runtime ----------------------------------------------------------------

log "Assembling $name"
rt="$work/$name"
mkdir -p "$rt/bin" "$rt/lib" "$rt/share/qemu"
install -m 0755 "$qemu_src/build/qemu-system-aarch64" "$qemu_src/build/qemu-img" "$rt/bin/"
install -m 0644 "$qemu_src/pc-bios/efi-virtio.rom" "$rt/share/qemu/"
for fd in edk2-aarch64-code.fd edk2-arm-vars.fd; do
  bunzip2 -c "$qemu_src/pc-bios/$fd.bz2" > "$rt/share/qemu/$fd"
done
for lib in \
  "$virgl/lib/libvirglrenderer.1.dylib" \
  "$epoxy/lib/libepoxy.0.dylib" \
  "$angle/lib/libEGL.dylib" "$angle/lib/libGLESv2.dylib" \
  "$glib/lib/libglib-2.0.0.dylib" \
  "$gettext/lib/libintl.8.dylib" \
  "$pcre2/lib/libpcre2-8.0.dylib" \
  "$pixman/lib/libpixman-1.0.dylib" \
  "$slirp/lib/libslirp.0.dylib"; do
  install -m 0755 "$lib" "$rt/lib/"
done
# GLib also links gmodule/gobject/gio on some builds: take whatever
# QEMU needs from the glib bottle.
otool -L "$rt/bin/qemu-system-aarch64" "$rt/bin/qemu-img" | awk 'NR > 1 {print $1}' |
  grep -o 'lib[gG][a-z]*-2\.0\.0\.dylib' | sort -u | while read -r l; do
    [[ -f "$rt/lib/$l" ]] || install -m 0755 "$glib/lib/$l" "$rt/lib/"
  done

# Relocate: every non-system dependency must resolve to lib/, through
# @executable_path (binaries) or @loader_path (libraries). A dependency
# that isn't in lib/ fails the build rather than loading from the host.
images=("$rt"/bin/* "$rt"/lib/*.dylib)
for image in "${images[@]}"; do
  chmod u+w "$image"
  if [[ $image == "$rt/lib/"* ]]; then
    install_name_tool -id "@rpath/${image##*/}" "$image" 2>/dev/null
    prefix=@loader_path
  else
    prefix=@executable_path/../lib
  fi
  self=$(otool -D "$image" | sed -n 2p)
  otool -L "$image" | awk 'NR > 1 {print $1}' | while read -r d; do
    case "$d" in /System/*|/usr/lib/*|"$self") continue ;; esac
    [[ -f "$rt/lib/${d##*/}" ]] || die "${image##*/} needs ${d}, which isn't bundled"
    [[ "$d" == "$prefix/${d##*/}" ]] || install_name_tool -change "$d" "$prefix/${d##*/}" "$image" 2>/dev/null
  done
  otool -l "$image" | awk '$1 == "cmd" {r = ($2 == "LC_RPATH")} r && $1 == "path" {print $2}' |
    while read -r p; do install_name_tool -delete_rpath "$p" "$image" 2>/dev/null; done
  install_name_tool -add_rpath "$prefix" "$image" 2>/dev/null
done
# libepoxy finds ANGLE with dlopen, not through the load commands above.
for l in libEGL.dylib libGLESv2.dylib; do
  grep -aq "$l" "$rt/lib/libepoxy.0.dylib" || die "libepoxy doesn't load $l: check the bottle"
done

# Ad-hoc signatures; QEMU needs the hypervisor entitlement for HVF.
for image in "${images[@]}"; do
  xattr -c "$image"
  if [[ $image == */qemu-system-aarch64 ]]; then
    codesign --force --sign - --entitlements "$qemu_dir/hvf.entitlements" "$image"
  else
    codesign --force --sign - "$image"
  fi
done

# --- Checks -----------------------------------------------------------------

log "Checking $name"
unset DYLD_FALLBACK_LIBRARY_PATH
q="$rt/bin/qemu-system-aarch64"
"$q" --version | grep -q "version $qemu_version" || die "qemu-system-aarch64 doesn't run"
"$rt/bin/qemu-img" --version >/dev/null || die "qemu-img doesn't run"
for image in "${images[@]}"; do
  otool -l "$image" | awk '$1 == "minos" {print $2}' | while read -r v; do
    [[ $v == "$macos_min" || $(printf '%s\n' "$v" "$macos_min" | sort -V | tail -1) == "$macos_min" ]] ||
      die "${image##*/} needs macOS $v"
  done
  ! otool -L "$image" | awk 'NR > 1 {print $1}' | grep -vE '^(/System/|/usr/lib/|@rpath/|@loader_path/|@executable_path/)' ||
    die "${image##*/} still links outside the runtime"
done
"$q" -accel help | grep -qx hvf || die "no HVF"
"$q" -machine virt,help | grep -q 'virtualization=' || die "no virtualization= on virt"
"$q" -display help | grep -qx cocoa || die "no Cocoa display"
devices=$("$q" -device help)
for d in virtio-gpu-gl-pci virtio-gpu-pci virtio-balloon-pci virtio-net-pci virtio-rng-pci \
         virtio-scsi-pci scsi-cd virtio-blk-pci qemu-xhci usb-kbd usb-tablet; do
  grep -q "name \"$d\"" <<<"$devices" || die "no $d device"
done
"$q" -machine none -accel qtest -netdev help | grep -qx user || die "no user networking (slirp)"
grep -aq hv_vm_config_set_el2_enabled "$q" || die "no HVF nested virtualization"
codesign -d --entitlements - "$q" 2>&1 | grep -q com.apple.security.hypervisor ||
  die "not signed with the hypervisor entitlement"

rm -rf "${out_dir:?}/$name" "$out_dir/$name.tar.gz"
ditto "$rt" "$out_dir/$name"
tar -czf "$out_dir/$name.tar.gz" -C "$out_dir" "$name"
log "Done: $out_dir/$name ($(du -sh "$out_dir/$name" | cut -f1)), $out_dir/$name.tar.gz"
