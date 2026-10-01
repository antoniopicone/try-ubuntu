#!/usr/bin/env bash
# Builds icloud-linux (iCloud Drive through FUSE: icloudctl, icloudd,
# icloud-status) for the live image, where the Backup app uses it for
# backups on iCloud Drive. Rust, from Ubuntu 26.04's own toolchain, in the
# builder container; build-rootfs.sh installs the binaries from
# $ICLOUD_LINUX_OUT. Skipped when that build is already in the cache.
set -euo pipefail

: "${ICLOUD_LINUX_OUT:?}" "${WORK:?}"

# Pinned: antoniopicone/icloud-linux master, as a tarball checked by sha256
# (Cargo.lock pins the crates, --locked holds the build to it).
ICLOUD_LINUX_COMMIT=f0c3664a38fc9229f434bc6d357ddd14d277e72f
ICLOUD_LINUX_SHA256=045383b625b760b878eac5b845877f8a78dcecf2c8de60936a4f3c54ba928a5b

stamp="$ICLOUD_LINUX_OUT/.built-$ICLOUD_LINUX_COMMIT"
if [[ -f "$stamp" ]]; then
  echo "==> icloud-linux ${ICLOUD_LINUX_COMMIT:0:12} already built, skipping"
  exit 0
fi

echo "==> icloud-linux ${ICLOUD_LINUX_COMMIT:0:12}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends cargo rustc pkg-config >/dev/null

src="$WORK/icloud-linux"
rm -rf "$src" && mkdir -p "$src"
curl -fsSL "https://codeload.github.com/antoniopicone/icloud-linux/tar.gz/$ICLOUD_LINUX_COMMIT" \
  -o "$WORK/icloud-linux.tar.gz"
echo "$ICLOUD_LINUX_SHA256  $WORK/icloud-linux.tar.gz" | sha256sum -c --quiet
tar xzf "$WORK/icloud-linux.tar.gz" -C "$src" --strip-components=1
# The installer window isn't built: the Backup app does the sign-in.
CARGO_HOME="$WORK/cargo-home" cargo build --release --locked -q --manifest-path "$src/Cargo.toml" \
  -p icloudctl -p icloudd -p icloud-status

rm -rf "$ICLOUD_LINUX_OUT" && mkdir -p "$ICLOUD_LINUX_OUT"
install -m 755 "$src"/target/release/{icloudctl,icloudd,icloud-status} "$ICLOUD_LINUX_OUT/"
install -m 644 "$src/README.md" "$ICLOUD_LINUX_OUT/README.md"
touch "$stamp"
rm -rf "$src" "$WORK/icloud-linux.tar.gz"
