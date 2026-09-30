# Builder image for the live ISO. Runs natively on arm64 (Apple Silicon
# podman machine), so debootstrap/chroot need no emulation. It also builds
# the GNOME 51 backport (Debian source packages; build-gnome.sh installs
# their build dependencies).
FROM docker.io/library/ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git curl gnupg python3 \
      debootstrap ubuntu-keyring \
      btrfs-progs dosfstools mtools xorriso zstd \
      build-essential dpkg-dev apt-utils fakeroot \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
