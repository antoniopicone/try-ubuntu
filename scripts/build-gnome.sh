#!/usr/bin/env bash
# Backports GNOME 51 to Ubuntu 26.04: rebuilds, against 26.04, the Ubuntu
# 26.10 ($BACKPORT_SUITE) source packages of GNOME 51's core and of the
# libraries it needs newer versions of, in dependency order. The .debs go
# into a local apt repository ($GNOME_REPO) that build-rootfs.sh installs
# from, and every package builds against the ones before it. A package is
# skipped when the repository already holds its build (cached in the podman
# volume): ~1-2 hours the first time. Local fixes in
# $GNOME_PATCH_DIR/<source>/*.patch go on top of the package's own patches.
#
# Runs in the builder container (an Ubuntu 26.04 image), which it changes:
# build dependencies and the backported libraries get installed into it.
set -euo pipefail

: "${GNOME_REPO:?}" "${GNOME_PATCH_DIR:?}" "${CACHE_DIR:?}" "${MIRROR:?}"
: "${BACKPORT_SUITE:=stonking}"

# Sources to rebuild, in build order. The GNOME 51 core: gsettings-desktop-schemas,
# gnome-desktop, gnome-session, gnome-settings-daemon, mutter, gdm3,
# xdg-desktop-portal-gnome, nautilus, gnome-shell, gnome-control-center, and
# the Extensions app (26.04's pins gnome-shell to its exact 50.x version).
# The rest are what those need at build time in a newer version than 26.04
# has (debhelper 14 is only a build tool), and ibus, which gtk4 4.24 Breaks
# in 26.04's version. Everything else (libc, systemd, Mesa, mozjs...) stays
# 26.04's.
BACKPORTS=(
  debhelper wayland wayland-protocols glib2.0 pango1.0
  gsettings-desktop-schemas accountsservice ubuntu-insights gexiv2 gjs
  gnome-desktop ibus gtk4 gnome-session gnome-settings-daemon mutter gdm3
  xdg-desktop-portal-gnome nautilus gnome-shell gnome-control-center
  gnome-extensions-app
)
# Appended to the 26.10 version: sorts above 26.04's and below 26.10's.
SUFFIX="~26.04.1"

export DEBIAN_FRONTEND=noninteractive
# No tests, docs or LTO: faster, and LTO links need more memory than the
# podman machine has. One job per GB of RAM, at most one per CPU. "nodoc" is
# a build option only, not a profile: some packages (pango) still build
# their man pages without the tools the profile leaves out. The -fno-lto
# flags are user-level, so debian/rules files that set their own
# DEB_BUILD_MAINT_OPTIONS can't turn LTO back on.
jobs=$(awk '/^MemTotal:/ { j = int($2 / 1000000); print (j < 1 ? 1 : j) }' /proc/meminfo)
(( jobs > $(nproc) )) && jobs=$(nproc)
export DEB_BUILD_OPTIONS="nocheck nodoc parallel=$jobs"
export DEB_BUILD_PROFILES="nocheck noinsttest"
export DEB_BUILD_MAINT_OPTIONS="optimize=-lto"
export DEB_CFLAGS_APPEND=-fno-lto DEB_CXXFLAGS_APPEND=-fno-lto DEB_LDFLAGS_APPEND=-fno-lto

# The 26.10 sources (apt checks them against the signed archive) and the
# local repository of what is already rebuilt.
cat > /etc/apt/sources.list.d/gnome-backport-src.sources <<EOF
Types: deb-src
URIs: $MIRROR
Suites: $BACKPORT_SUITE
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
mkdir -p "$GNOME_REPO"
repo_list=/etc/apt/sources.list.d/gnome-backports.list
echo "deb [trusted=yes] file:$GNOME_REPO ./" > "$repo_list"
refresh_repo() {
  (cd "$GNOME_REPO" && apt-ftparchive packages . > Packages)
  apt-get update -qq -o Dir::Etc::SourceList="$repo_list" -o Dir::Etc::SourceParts=- \
    -o APT::Get::List-Cleanup=0
}
refresh_repo
apt-get update -qq

for src in "${BACKPORTS[@]}"; do
  # The only deb-src is $BACKPORT_SUITE: one version per source.
  ver=$(apt-cache showsrc --only-source "$src" | awk '/^Version:/ { print $2; exit }')
  [[ -n "$ver" ]] || { echo "no $BACKPORT_SUITE source for $src" >&2; exit 1; }
  local_patches=("$GNOME_PATCH_DIR/$src"/*.patch)
  [[ -e "${local_patches[0]}" ]] || local_patches=()
  stamp="$GNOME_REPO/.built-$src-${ver//:/%}"
  if ((${#local_patches[@]})); then
    stamp+="-$(cat "${local_patches[@]}" | sha256sum | cut -c1-12)"
  fi
  if [[ -f "$stamp" ]]; then
    echo "==> $src $ver already backported, skipping"
    continue
  fi

  echo "==> Backporting $src $ver"
  work="$CACHE_DIR/gnome-build/$src"
  rm -rf "$work" && mkdir -p "$work"
  (cd "$work" && apt-get source -qq --only-source "$src=$ver")
  dir=$(find "$work" -mindepth 1 -maxdepth 1 -type d)
  {
    printf '%s (%s%s) resolute; urgency=medium\n\n' "$src" "$ver" "$SUFFIX"
    printf '  * Rebuild of the %s package for Ubuntu 26.04 (live ISO).\n\n' "$BACKPORT_SUITE"
    printf ' -- Live ISO builder <live@localhost>  %s\n\n' "$(date -R)"
    cat "$dir/debian/changelog"
  } > "$work/changelog" && mv "$work/changelog" "$dir/debian/changelog"
  if ((${#local_patches[@]})); then
    mkdir -p "$dir/debian/patches/live"
    for patch in "${local_patches[@]}"; do
      echo "==> Applying ${patch##*/}"
      cp "$patch" "$dir/debian/patches/live/"
      echo "live/${patch##*/}" >> "$dir/debian/patches/series"
    done
    # dpkg-buildpackage applies them (3.0 quilt), and fails if one doesn't apply.
  fi

  apt-get build-dep -y -qq --no-install-recommends -P "${DEB_BUILD_PROFILES// /,}" "$dir" >/dev/null
  (cd "$dir" && dpkg-buildpackage -b -uc -us -P"${DEB_BUILD_PROFILES// /,}") \
    > "$work/build.log" 2>&1 || { tail -60 "$work/build.log" >&2; exit 1; }
  mv "$work"/*.deb "$GNOME_REPO/"
  refresh_repo
  touch "$stamp"
  rm -rf "$dir"
done
