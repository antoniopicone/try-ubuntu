#!/usr/bin/env bash
# GNOME 50 is Ubuntu 26.04's own: this only rebuilds the GNOME sources that
# have local fixes ($GNOME_PATCH_DIR/<source>/*.patch, on top of the
# package's own patches), from 26.04's latest version (resolute-updates,
# resolute-security). The .debs go into a local apt repository
# ($GNOME_REPO) that build-rootfs.sh installs from. A package is skipped
# when the repository already holds its build (cached in the podman volume).
#
# Runs in the builder container (an Ubuntu 26.04 image), which it changes:
# the build dependencies get installed into it.
set -euo pipefail

: "${GNOME_REPO:?}" "${GNOME_PATCH_DIR:?}" "${CACHE_DIR:?}" "${MIRROR:?}"

# Sources to rebuild: those with local fixes.
REBUILDS=()
for dir in "$GNOME_PATCH_DIR"/*/; do
  compgen -G "$dir*.patch" >/dev/null && REBUILDS+=("$(basename "$dir")")
done
# Appended to 26.04's version: sorts above it, so apt prefers the rebuild.
SUFFIX="+live1"

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

# 26.04's sources (apt checks them against the signed archive) and the
# local repository of what is already rebuilt.
cat > /etc/apt/sources.list.d/gnome-src.sources <<EOF
Types: deb-src
URIs: $MIRROR
Suites: resolute resolute-updates resolute-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
mkdir -p "$GNOME_REPO"
repo_list=/etc/apt/sources.list.d/gnome-backports.list
echo "deb [trusted=yes] file:$GNOME_REPO ./" > "$repo_list"
# A Release file lists the indexes that exist: without one, apt probes
# Packages.{gz,xz,...} and warns about each one that's missing.
refresh_repo() {
  (cd "$GNOME_REPO" && apt-ftparchive packages . > Packages &&
     gzip -9nkf Packages && apt-ftparchive release . > Release)
  apt-get update -qq -o Dir::Etc::SourceList="$repo_list" -o Dir::Etc::SourceParts=- \
    -o APT::Get::List-Cleanup=0
}
refresh_repo
apt-get update -qq

# While a package builds (its output is in build.log), where it's at: the
# debhelper step and ninja's count, as "nautilus: dh_auto_build [210/312]".
# One line, rewritten: install.sh shows it next to its spinner.
progress() {  # $1: the source, $2: its build.log
  local now last='' width=0
  while sleep 5; do
    now=$(awk '
      /^ +dh_[a-z_]+/ { step = $1; count = "" }
      /^ +debian\/rules [a-z_]+_dh_/ { step = $2; sub(/^[a-z_]+_dh_/, "dh_", step); count = "" }
      match($0, /^\[[0-9]+\/[0-9]+\]/) { count = " " substr($0, 1, RLENGTH) }
      END { print step count }' "$2" 2>/dev/null) || continue
    [[ -n "$now" && "$now" != "$last" ]] || continue
    last=$now now="    $1: $now"
    (( ${#now} > width )) && width=${#now}
    printf '\r%-*s' "$width" "$now"
  done
}

for src in "${REBUILDS[@]}"; do
  # The latest of the suites' versions
  ver=
  for v in $(apt-cache showsrc --only-source "$src" | awk '/^Version:/ { print $2 }'); do
    if [[ -z "$ver" ]] || dpkg --compare-versions "$v" gt "$ver"; then
      ver=$v
    fi
  done
  [[ -n "$ver" ]] || { echo "no 26.04 source for $src" >&2; exit 1; }
  local_patches=("$GNOME_PATCH_DIR/$src"/*.patch)
  [[ -e "${local_patches[0]}" ]] || local_patches=()
  stamp="$GNOME_REPO/.built-$src-${ver//:/%}"
  if ((${#local_patches[@]})); then
    stamp+="-$(cat "${local_patches[@]}" | sha256sum | cut -c1-12)"
  fi
  if [[ -f "$stamp" ]]; then
    echo "==> $src $ver already rebuilt, skipping"
    continue
  fi

  echo "==> Rebuilding $src $ver"
  work="$CACHE_DIR/gnome-build/$src"
  rm -rf "$work" && mkdir -p "$work"
  # apt downloads as _apt: it must be able to write there, or it falls back
  # to root with a warning.
  chown _apt "$work"
  (cd "$work" && apt-get source -qq --only-source "$src=$ver")
  dir=$(find "$work" -mindepth 1 -maxdepth 1 -type d)
  {
    printf '%s (%s%s) resolute; urgency=medium\n\n' "$src" "$ver" "$SUFFIX"
    printf '  * Rebuild with local fixes (live ISO).\n\n'
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
  progress "$src" "$work/build.log" &
  progress_pid=$!
  built=0
  (cd "$dir" && dpkg-buildpackage -b -uc -us -P"${DEB_BUILD_PROFILES// /,}") \
    > "$work/build.log" 2>&1 || built=$?
  kill "$progress_pid" 2>/dev/null || true
  wait "$progress_pid" 2>/dev/null || true
  # The end of the line of progress
  echo
  (( built == 0 )) || { tail -60 "$work/build.log" >&2; exit 1; }
  mv "$work"/*.deb "$GNOME_REPO/"
  refresh_repo
  touch "$stamp"
  rm -rf "$dir"
done
