#!/usr/bin/env bash
# Builds apfs-fuse (read-only APFS through FUSE: Mac disks) for the live
# image: it's in no Ubuntu archive. Runs in the builder container (Ubuntu
# 26.04, like the image), which gets the build dependencies; build-rootfs.sh
# installs the binaries from $APFS_FUSE_OUT. Skipped when that build is
# already in the cache.
set -euo pipefail

: "${APFS_FUSE_OUT:?}" "${WORK:?}"

# Pinned: sgan81/apfs-fuse master (it has no releases) and its lzfse
# submodule, as tarballs checked by sha256.
APFS_FUSE_COMMIT=66b86bd525e8cb90f9012543be89b1f092b75cf3
APFS_FUSE_SHA256=e78e71e87d8ba182822ec34233189141b8816c9a3f700c9a22f6dc1480afee51
LZFSE_COMMIT=e634ca58b4821d9f3d560cdc6df5dec02ffc93fd
LZFSE_SHA256=ca98aa6644d44500e3315858daa747ce15bd06d49e3edb12a5458e5525e8ebdb

stamp="$APFS_FUSE_OUT/.built-$APFS_FUSE_COMMIT"
if [[ -f "$stamp" ]]; then
  echo "==> apfs-fuse ${APFS_FUSE_COMMIT:0:12} already built, skipping"
  exit 0
fi

echo "==> apfs-fuse ${APFS_FUSE_COMMIT:0:12}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  cmake g++ make libfuse3-dev libbz2-dev libattr1-dev zlib1g-dev >/dev/null

src="$WORK/apfs-fuse"
rm -rf "$src" && mkdir -p "$src/3rdparty/lzfse"
curl -fsSL "https://codeload.github.com/sgan81/apfs-fuse/tar.gz/$APFS_FUSE_COMMIT" -o "$WORK/apfs-fuse.tar.gz"
echo "$APFS_FUSE_SHA256  $WORK/apfs-fuse.tar.gz" | sha256sum -c --quiet
curl -fsSL "https://codeload.github.com/lzfse/lzfse/tar.gz/$LZFSE_COMMIT" -o "$WORK/lzfse.tar.gz"
echo "$LZFSE_SHA256  $WORK/lzfse.tar.gz" | sha256sum -c --quiet
tar xzf "$WORK/apfs-fuse.tar.gz" -C "$src" --strip-components=1
tar xzf "$WORK/lzfse.tar.gz" -C "$src/3rdparty/lzfse" --strip-components=1

# GCC 15: PList.h uses uint8_t/uint32_t without <cstdint>, which no longer
# comes in through <memory>.
sed -i '1i #include <cstdint>' "$src/ApfsLib/PList.h"
# CMake 4 dropped compatibility with cmake_minimum_required below 3.5.
cmake -S "$src" -B "$src/build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -Wno-dev >/dev/null
make -s -C "$src/build" -j"$(nproc)" apfs-fuse apfsutil

rm -rf "$APFS_FUSE_OUT" && mkdir -p "$APFS_FUSE_OUT"
install -m 755 "$src/build/apfs-fuse" "$src/build/apfsutil" "$APFS_FUSE_OUT/"
install -m 644 "$src/LICENSE" "$APFS_FUSE_OUT/LICENSE"
install -m 644 "$src/3rdparty/lzfse/LICENSE" "$APFS_FUSE_OUT/LICENSE.lzfse"
touch "$stamp"
rm -rf "$src" "$WORK/apfs-fuse.tar.gz" "$WORK/lzfse.tar.gz"
