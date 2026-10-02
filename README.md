# try-ubuntu

A live ISO of a minimal Ubuntu for arm64, to try the amazing penguin ;)

- Ubuntu 26.04 LTS (resolute) with a minimal **GNOME 51**, backported from
  26.10
- boots with Limine (EFI) and Plymouth
- runs on a btrfs root with subvolumes, managed by snapper; with a
  persistent disk, you can boot any snapshot from the Limine menu
- boots from the command line with QEMU; the live session starts in your
  shell's language

## Try it

On macOS or Linux, one command downloads the ISO from the
[latest release](https://github.com/antoniopicone/try-ubuntu/releases/latest),
gets QEMU and boots the live session:

```bash
curl -fsSL https://raw.githubusercontent.com/antoniopicone/try-ubuntu/main/install.sh | sh
```

Options after `sh -s --` go to [run-qemu.sh](run-qemu.sh), except
`--rebuild`, `--arch` and `--on-usb`:

```bash
curl -fsSL https://raw.githubusercontent.com/antoniopicone/try-ubuntu/main/install.sh | sh -s -- --lang de_DE --no-persist
curl -fsSL https://raw.githubusercontent.com/antoniopicone/try-ubuntu/main/install.sh | sh -s -- --rebuild
curl -fsSL https://raw.githubusercontent.com/antoniopicone/try-ubuntu/main/install.sh | sh -s -- --arch x86
curl -fsSL https://raw.githubusercontent.com/antoniopicone/try-ubuntu/main/install.sh | sh -s -- --arch x86 --on-usb
```

- **Which ISO**: `--arch arm` (the default) or `--arch x86`. The releases
  have `ubuntu-live-arm64.iso` and `ubuntu-live-amd64.iso`. An ISO runs
  with hardware acceleration on a host of its own architecture (hvf on
  Apple Silicon or an Intel Mac, kvm on Linux), and emulated (TCG, slow)
  on the other.
- **QEMU**: on Apple Silicon, the release's own build (see
  [QEMU for Apple Silicon](#qemu-for-apple-silicon)), with GPU acceleration
  and nested virtualization; nothing gets installed system-wide. On an Intel
  Mac it's Homebrew's (`brew install qemu`), and on Linux it's installed with
  apt (Debian, Ubuntu), dnf (Fedora) or pacman (Arch), together with the
  UEFI firmware (AAVMF or OVMF; this uses sudo). x86 ISOs always use the
  system's `qemu-system-x86_64` (Homebrew's on a Mac).
- **Files**: the ISO, the persistent disk and `run-qemu.sh` go in
  `~/.local/share/try-ubuntu` (set `TRY_UBUNTU_DIR` to change it). The ISO
  is checked against the release's `SHA256SUMS`, and an interrupted
  download resumes.
- **Updates**: running it again boots the same ISO, or downloads the newer
  one when there's a new release. The old persistent disk only works with
  its own ISO, so it's moved aside to `persist-<tag>.qcow2` (see
  [How the live btrfs works](#how-the-live-btrfs-works)).
- **Starting over**: `--rebuild` deletes what the script downloaded and the
  caches (the ISO, partial downloads, QEMU for Apple Silicon, `run-qemu.sh`,
  and the kernel `run-qemu.sh` extracts from the ISO for nested
  virtualization), then downloads them again from the latest release. The
  persistent disks and the UEFI variables (`efivars.fd`) stay. A persistent
  disk is still moved aside when the latest release isn't the one it was
  made with. Homebrew's or the distribution's QEMU isn't touched.
- **A USB stick for a real computer** (`--on-usb`): see
  [On a real computer](#on-a-real-computer).

## Build it

```bash
./build.sh --xkb it          # → dist/ubuntu-live-arm64.iso (~1.4 GB)
./build.sh --arch x86        # → dist/ubuntu-live-amd64.iso (emulated on Apple Silicon: slow)
./build.sh --hardware        # → dist/ubuntu-live-arm64-hardware.iso, for real computers
./qemu/build.sh              # macOS: → dist/qemu-macos-arm64 (optional, GPU + nested virtualization)
./run-qemu.sh                # boot it in a window (--serial: serial console in the terminal too)
./run-qemu.sh --lang de_DE   # boot in German instead of the host's language
./run-qemu.sh --no-persist   # RAM only (by default changes and snapshots go to a persistent disk)
./mount-home.sh              # macOS, VM off: your home on the persistent disk, in the Finder
```

`run-qemu.sh` attaches a persistent disk by default (see
[How the live btrfs works](#how-the-live-btrfs-works)), so what you set up
survives reboots. After `./build.sh` makes a new ISO, the next
`./run-qemu.sh` moves the old disk aside and starts a new one.

From a checkout, `run-qemu.sh` looks for QEMU in `dist/qemu-macos-arm64`,
which only `./qemu/build.sh` creates there (install.sh downloads it to
`~/.local/share/try-ubuntu/dist`, not to the checkout). Without it, it uses the
QEMU on `PATH` (e.g. Homebrew's), and GNOME renders in software.

On first boot the live user (`ubuntu`) logs in by itself and the welcome
app takes over: it creates your user and logs out to GDM (see
[The desktop](#the-desktop)).

## On a real computer

```bash
./install.sh --arch x86 --on-usb      # from a checkout, or through curl | sh -s -- --arch x86 --on-usb
```

`install.sh --on-usb` makes a live USB stick for a real computer:

1. **It builds the ISO locally.** The releases' ISOs are made for QEMU:
   the "virtual" kernel cut down to what a VM needs, and no firmware.
   `build.sh --hardware` makes `ubuntu-live-<arch>-hardware.iso` instead,
   with the generic kernel, all of `linux-firmware` (every vendor's: Wi-Fi,
   GPUs, Bluetooth), Intel's sound DSP firmware, ALSA's device profiles,
   wpa_supplicant, the Vulkan drivers and, on x86, the CPU microcode. That
   ISO is over GitHub's 2 GiB limit for a release asset, hence the local
   build. It uses the release's sources (or the checkout install.sh is run
   from) and podman. On a Mac, install.sh installs podman with Homebrew and
   creates a rootful machine if there's none. The first build compiles
   GNOME 51, which takes 1–2 hours. For x86 on Apple Silicon everything
   runs emulated (qemu-user in the podman machine), so it takes many
   hours. Later builds reuse the cache. In an emulated build, the ISO
   step runs in a native container on the same cache, since qemu-user
   can't pass btrfs's ioctls (snapshot, resize) on. The checks that run
   downloaded binaries (uv, rclone, Ghostty's config) only warn there,
   since some can't run under the emulator. Their sha256 is checked
   anyway, and native builds run them. Other arguments go to build.sh
   (e.g. `--xkb it`).
2. **It writes the ISO to a USB stick.** It lists the USB disks (`diskutil`
   on macOS, `lsblk` on Linux) and asks which one to use. You confirm by
   typing the disk's name, and it writes the ISO with `dd`. The ISO is a
   hybrid image, so the stick boots like a CD.

The computer has to boot it through UEFI with **Secure Boot off**, because
Limine isn't signed. In the live session, the welcome app can install
Ubuntu on the computer.

### Installing on a disk

Right after the keyboard, the welcome app lists the disks the system can go
on ([install-system](overlay/usr/local/lib/live-install/install-system)
`list`). Each needs at least 20 GB:

- **the whole disk**, erased: GPT, a 512 MiB EFI system partition and a
  btrfs partition;
- **its free space**, next to what's already there (Windows, say): on a
  GPT disk, the two partitions go in its largest unpartitioned stretch,
  and the other partitions stay as they are.

"Keep trying it" is the default. A disk the live system itself stands on
(the USB stick, the persistent disk) or with a mounted partition is never
offered. Choosing a disk asks for confirmation, then `install-system
install` does the work. It runs through `pkexec`, under a polkit rule that
lets the live session run it without a password. It refuses on an
installed system or once the welcome app is done, so the rule can't be
used to erase disks later.

**How the system gets to the disk.** The running root filesystem is the
ISO's read-only seed plus a writable sprout, in RAM or on the persistent
disk (see [How the live btrfs works](#how-the-live-btrfs-works)).
install-system adds the new btrfs partition to it with `btrfs device add`,
then removes the sprout and the seed with `btrfs device remove`: btrfs
moves everything they held onto the partition while the system keeps
running. Nothing is copied by hand. The subvolumes, the snapper
snapshots, and what the session already changed (language, keyboard,
theme) all come along, and the live medium is no longer needed: its
loops are detached and it's unmounted. Then:

- `/etc/fstab` mounts `@`, `@home`, `@var` and `@snapshots` from the
  partition, and the EFI system partition on `/boot/efi`. The btrfs
  filesystem (and its GPT partition) is named `Ubuntu-root`.
- The kernel the ISO booted goes back in `/boot` (the ISO keeps it as
  `live/vmlinuz`), with an initramfs for booting from disk
  (`update-initramfs`).
- [live-limine-update](overlay/usr/local/sbin/live-limine-update) puts
  Limine on the EFI system partition, along with copies of the two newest
  kernels and their initramfs (on arm64, the raw `Image` that
  `unzboot.py` extracts), and writes its menu: `root=UUID=… rootflags=subvol=@`.
  The kernel's and initramfs-tools' hooks (`/etc/kernel/postinst.d`,
  `postrm.d`, `/etc/initramfs/post-update.d`) run it again on every kernel
  update. On the live system it does nothing.
- `efibootmgr` adds a boot entry, "Ubuntu (try-ubuntu)", first in the boot
  order. Limine is also at the fallback path `\EFI\BOOT\`, for firmware
  that loses boot entries.

The welcome app then goes on as usual: account, picture, appearance. Its
last page doesn't log out: it asks to remove the USB stick and offers
**Restart**. The `ubuntu` user is deleted at that first boot from the disk
(live-retire-user.service, before GDM).

## What's in it

| | |
|---|---|
| Base | `debootstrap --variant=minbase` resolute with a hand-picked package set (no `ubuntu-minimal` or console-setup): openssh, sudo |
| Kernel | `linux-image-virtual` (7.0), pruned to the modules a VM needs, with no firmware. initramfs-tools with zstd -19 |
| Boot | **Limine** 11 (arm64 UEFI), with a menu to boot snapper snapshots, and Plymouth with the `spinner` theme (GNOME's). The ISO is hybrid (El Torito EFI + appended GPT ESP), so it also boots when written with `dd` to a USB stick |
| Filesystem | btrfs with the subvolumes `@` → `/`, `@home` → `/home`, `@var` → `/var`, `@snapshots` → `/.snapshots` (flat layout, `compress=zstd:1`). **snapper** manages `/` (snapshot #1 is the image as built) and `/home` (every hour: *Previous Versions* in Files) |
| Desktop | a minimal **GNOME 51**: Shell, Settings, the vanilla GNOME session, GDM (see [The desktop](#the-desktop)) |
| Theme | dark style with GNOME's blue accent, Adwaita Sans, Yaru icons, and **one of Ubuntu's stock wallpapers, picked at random at each build** |
| Apps | **ghostty** (JetBrains Mono Nerd Font, Catppuccin Mocha; OpenGL in software under QEMU's virgl, which lacks the OpenGL 4.3 it needs), with **Ptyxis** when it can't start, **Nautilus** (with *Open in Ghostty* and *Previous Versions*), **Brave Origin** (in the desktop's language and light/dark style), GNOME Software (with **Flatpak** and Flathub), Calculator, Papers (PDF), Fonts, Text Editor, Disks, Resources, Extensions, **Cloud Config** (Google Drive, OneDrive, Dropbox, Nextcloud and iCloud Drive in Files), **Cloud Backup** (hourly, end-to-end encrypted backups of your home folder with restic, and restore, to one of those clouds, Samba or SFTP) |
| Fonts | Adwaita Sans; Liberation, **Carlito** and **Caladea** (metric-compatible with Arial/Times New Roman/Courier New and Calibri/Cambria, so Office documents keep their layout); JetBrains Mono; **JetBrains Mono Nerd Font** (GNOME's monospace font and Ghostty's) and **Hack Nerd Font Mono** |
| Network | NetworkManager (via netplan, as on Ubuntu Desktop) |
| QEMU integration | sound (virtio-sound, PipeWire), the clipboard shared with the QEMU window (**spice-vdagent**), the host's shared folder (9p + **bindfs**, see [Running](#running)) |
| Services | polkit, UPower, power-profiles-daemon, BlueZ, GeoClue, avahi-daemon (+ nss-mdns), Tailscale, ufw |
| Tools | podman (rootless: uidmap + passt), git, curl, wget, **eza** (`ls` is `eza --icons=always`), **apfs-fuse** (Mac disks, read-only, also from Nautilus) |
| Development | Python 3.14 with `pip` and `venv`, **uv** / uvx (0.12, from Astral's releases), **zsh** (the default shell) with the **pure** prompt |
| Languages | English, plus Italian, Spanish, French, German and Portuguese (Brazil): locales and Ubuntu's `language-pack-*-base` / `language-pack-gnome-*-base` |
| Excluded | ModemManager, pinned to priority -1 so no dependency can pull it in |

### Package sources

Each extra repository has its signing key vendored in
[overlay/etc/apt/keyrings/](overlay/etc/apt/keyrings/). The build checks
each keyring's fingerprints and fails if they don't match exactly.

| Repository | What it provides | Key |
|---|---|---|
| Ubuntu `resolute` (main, restricted, universe) | base system | `ubuntu-keyring` |
| Flathub (a Flatpak remote, [scripts/flathub.flatpakrepo](scripts/flathub.flatpakrepo)) | Flatpak apps, in GNOME Software | `6E5C05D9…4184DD4D907A7CAE` |
| Ubuntu `stonking` (26.10) sources | GNOME 51, rebuilt for 26.04 (see [The desktop](#the-desktop)) | `ubuntu-keyring` |
| `brave-browser-apt-release.s3.brave.com` | Brave Origin (`brave-origin`, and `brave-keyring`, which then keeps the keyring up to date). Pinned so it provides **only** those | `DBF1A116…0686B78420038257`, `47D32A74…68D513D36A73CD96`, `B2A3DCA3…DE4EC67BE4B0DCA0` |
| `pkgs.tailscale.com` | tailscale | `2596A99E…458CA832957F5868` |

These files are pinned and checked with sha256, not taken from a
repository:
- [uv](https://github.com/astral-sh/uv) (`UV_*` in build-rootfs.sh)
- [pure](https://github.com/sindresorhus/pure) (`PURE_*`)
- [Limine](https://codeberg.org/Limine/Limine) (`LIMINE_*` in
  build-iso.sh)
- the GNOME Shell extensions (`EXTENSIONS` in desktop-gnome.sh)
- [Hack and JetBrains Mono Nerd Fonts](https://github.com/ryanoasis/nerd-fonts),
  the Mono variants only, JetBrains Mono in its four terminal styles
  (`HACK_NERD_*`, `JETBRAINS_NERD_*` in build-rootfs.sh)
- [apfs-fuse](https://github.com/sgan81/apfs-fuse) and its lzfse
  submodule, built from source by
  [scripts/build-apfs-fuse.sh](scripts/build-apfs-fuse.sh) (it has no
  releases: a pinned commit)

### Footprint

The ISO would be much larger without these measures:

- The package set is chosen by hand (see Base above), with no
  recommends.
- dpkg path-excludes skip docs, man pages, info pages, Qt translations and
  every translation except those of the image's languages
  ([overlay/etc/dpkg/dpkg.cfg.d](overlay/etc/dpkg/dpkg.cfg.d/01-live-excludes)).
  Ubuntu's language packs only cover what Ubuntu builds in main: universe
  apps (GNOME Software...) and the GNOME 51 backport ship their own.
- Kernel modules are cut down to filesystems, networking, crypto, virtio,
  USB/HID/SCSI/NVMe, the virtio-gpu DRM driver and virtio-sound. Other
  sound cards, other GPUs, wireless/ethernet NICs and media drivers are
  gone, and so is all firmware. The build fails if a required module was removed.
- glibc's extra charset converters (`libc-gconv-modules-extra`) are
  removed.
- Brave keeps only the translations for the image's languages (all of
  them take ~100 MB).
- `/boot` isn't in the rootfs: the kernel and initramfs sit only on the ISO.
- Snapshot #1 shares every extent with `@`, so it costs only metadata.
- The btrfs seed uses zstd:15.

What's left is mostly needed at runtime: LLVM for Mesa's llvmpipe
(software rendering), GNOME, Brave, GTK 4. Limine also needs the kernel
as a raw `Image` (~70 MB instead of the ~24 MB zboot vmlinuz, see below).

## How the live btrfs works

`live/rootfs.btrfs` on the ISO is a compressed btrfs image flagged as a
**seed device**. At boot, the initramfs script
([overlay/etc/initramfs-tools/scripts/btrfslive](overlay/etc/initramfs-tools/scripts/btrfslive),
chosen with `boot=btrfslive`) takes these steps:

1. It finds the medium by label (`UBUNTU_LIVE`, written to the initramfs's
   `conf.d/btrfslive` at build time) and loop-mounts the seed image
   read-only.
2. It adds a second "sprout" device. btrfs turns the seed into a writable
   copy-on-write filesystem, and everything written goes to the sprout:
   - **RAM** (default): a sparse file on tmpfs, lost at shutdown.
   - **persistent disk**: the QEMU disk with serial `ubuntu-persist`
     (`run-qemu.sh --persist`), or `btrfslive.persist=DEV`. A blank disk is
     claimed on first boot and reopened on later boots. A disk that holds
     anything else is never touched. The disk extends the seed of *that*
     ISO build, so after a rebuild btrfslive would reject it and run in RAM:
     `run-qemu.sh` records the ISO's checksum next to the disk
     (`persist.qcow2.iso`) and, when the ISO changes, moves the old disk
     aside to `persist-<date>.qcow2` and creates a new one.
3. It mounts `@` (or a snapshot, see below), `@home`, `@var` and
   `@snapshots` just as an installed system would.

This means the live session runs on real btrfs, so snapshots,
`btrfs subvolume`, compression and the rest all work.

### Browsing the persistent disk from macOS

[mount-home.sh](mount-home.sh) opens your home folder, as kept on the
persistent disk, in the Finder, with the VM switched off. The disk can't be
mounted on its own: it's a sprout, so it needs the seed of the ISO that
made it, and macOS can't read btrfs anyway. Like `build.sh`, the script
works in a privileged container on the podman machine:

1. It loads `nbd`, `isofs` and `btrfs` in the podman machine and builds a
   small image (`try-ubuntu-mount`: btrfs-progs, qemu-utils, Samba).
2. It loop-mounts the ISO and its `live/rootfs.btrfs` (the seed), attaches
   the qcow2 with `qemu-nbd --read-only`, and mounts the `@home` subvolume
   read-only. If the session didn't shut down cleanly, it skips the btrfs
   log (`rescue=nologreplay`), so the last few seconds before the crash
   don't show.
3. It shares the home folder over SMB on `127.0.0.1` only, with a random
   password for that run, then mounts it in `dist/home` with `mount_smbfs`
   and opens it in the Finder.
4. Ctrl-C unmounts it all: the Mac's mount, Samba, btrfs, the nbd and loop
   devices, and the container.

It refuses to start while a VM is using the disk (the disk would change
under the mount), or when `persist.qcow2.iso` says the disk belongs to
another ISO. Everything is read-only, so it can't damage the disk. Whose
home: by default, the user the welcome app created (the only folder in
`/home` other than `ubuntu`), or `ubuntu` if there's none yet.

| Option | |
|---|---|
| `--user NAME` | that user's home |
| `--all` | the whole `/home` |
| `--iso PATH`, `--persist FILE` | another ISO and disk (default: `dist/ubuntu-live-arm64.iso`, `dist/persist.qcow2`), e.g. a disk moved aside to `persist-<date>.qcow2` with the ISO it belongs to |
| `--at DIR` | where to mount it on the Mac (default: `dist/home`) |
| `--port PORT` | local port of the SMB server (default: 44545) |

It runs from a checkout, since install.sh doesn't download it. For the
files install.sh keeps, pass
`--iso ~/.local/share/try-ubuntu/dist/ubuntu-live-arm64.iso --persist ~/.local/share/try-ubuntu/dist/persist.qcow2`.

| Kernel parameter | |
|---|---|
| `btrfslive.ram=<MiB>` | size of the RAM sprout (default: 75% of RAM) |
| `btrfslive.persist=<DEV>` / `=no` | persistent sprout device / force RAM |
| `btrfslive.snapshot=<N>` / `=ask` | boot snapper snapshot N / list the snapshots and ask |
| `btrfslive.label=<LABEL>` | label of the live medium |

## Snapshots and Limine

- **snapper** (`/etc/snapper/configs/root`) snapshots `/`. You get:
  - snapshot #1, made at build time
  - one at every boot (`snapper-boot`)
  - one before every apt/dpkg run ([80-snapper](scripts/build-rootfs.sh))
  - any you make yourself with `sudo snapper create -d "…"`
  
  Snapshots survive reboots only with the persistent disk.
- **snapper** (`/etc/snapper/configs/home`) also snapshots `/home`, every
  hour (`snapper-timeline.timer`). It keeps 24 hourly, 7 daily and 4
  weekly ones, as long as they fit in half the disk. They live in
  `/home/.snapshots`, a subvolume of `@home` that
  [live-home-snapshots.service](overlay/etc/systemd/system/live-home-snapshots.service)
  makes at the first boot. They aren't in the Cloud Backup: run-backup
  stays on `@home` itself. `SYNC_ACL` lets the user (`ALLOW_USERS`: the
  live user, then the one the welcome app creates) list them and go into
  them. Inside, their files keep their own permissions.
- **Previous Versions** in Files: right-click a file or folder in a home
  folder, or a folder's background. A Nautilus extension
  ([live-file-versions.py](overlay/usr/share/nautilus-python/extensions/live-file-versions.py))
  opens [live-file-versions](overlay/usr/local/bin/live-file-versions):
  - **a file**: its distinct versions, newest first. Snapshots in which it
    didn't change count as one. Each version can be opened (read-only),
    saved as a copy next to the file ("name (version of …).ext"), or
    restored. Before restoring, snapper takes a snapshot, so the version
    being replaced shows up among the earlier ones.
  - **a folder**: the snapshots it's in, each opened in Files as the folder
    was then, to copy back what was deleted or changed.
- The **Limine menu** has a *Snapper snapshots* section:
  - *#1 Live image as built*
  - *Choose at boot*: the initramfs lists every snapshot, including the ones
    on the persistent disk, and asks which one to boot
- Booting a snapshot starts a **writable copy** of it (`@boot-snapshot`),
  and `@` itself is left untouched. The copy is dropped at the next normal
  boot. To keep that state, run **`live-rollback`**: it makes the booted
  snapshot the new `@` and keeps the previous one as `@old-<date>`.
- Limine boots the kernel with its Linux protocol, which needs the raw arm64
  `Image`. Ubuntu's vmlinuz is an EFI zboot binary, so
  [scripts/unzboot.py](scripts/unzboot.py) extracts the Image at build time.
- Limine's background is the build's wallpaper (its dark variant). Under
  QEMU with virtio-gpu, though, the firmware only offers a "Blt-only"
  display with no linear framebuffer. Limine then falls back to the
  firmware's text console, so its wallpaper and colors only show on
  hardware with a normal framebuffer. The menu works either way.

## Build

`build.sh` runs everything in a privileged **podman** container
(`ubuntu:26.04`, native arm64 on the podman machine on Apple Silicon):

1. [scripts/build-gnome.sh](scripts/build-gnome.sh) backports GNOME 51
   (see [The desktop](#the-desktop)). It's cached in the podman volume
   `try-ubuntu-cache`: ~1–2 hours the first time, then skipped.
2. [scripts/build-apfs-fuse.sh](scripts/build-apfs-fuse.sh) builds
   apfs-fuse, and [scripts/build-icloud-linux.sh](scripts/build-icloud-linux.sh)
   icloud-linux (Rust, with Ubuntu's toolchain), both cached the same way
   (~1 minute each).
3. [scripts/build-rootfs.sh](scripts/build-rootfs.sh) builds the rootfs,
   and sources [scripts/desktop-gnome.sh](scripts/desktop-gnome.sh) for
   GNOME's packages and configuration. It:
   - runs debootstrap
   - adds the extra repositories and installs the packages and the
     [overlay/](overlay/)
   - sets up Plymouth, ufw, rootless podman, snapper, uv, zsh + pure,
     Nerd Fonts, apfs-fuse, icloud-linux, Flathub and the default apps
   - picks the wallpaper
   - configures GNOME, GDM and the welcome app
   - slims the image down and builds the initramfs
4. [scripts/build-iso.sh](scripts/build-iso.sh) builds the ISO:
   - lays out the subvolumes and runs `mkfs.btrfs --rootdir --subvol`
   - loop-mounts the image to add snapper snapshot #1 (this is why
     `build.sh` passes the host's `/dev` to the container)
   - shrinks the image and runs `btrfstune -S 1`
   - writes the Limine menu and runs xorriso

Options: `--xkb LAYOUT` sets the keyboard layout for the session and the
login screen (default `us`), and `--clean` empties the cache. Each run
takes ~6 minutes once GNOME is cached.

## Running

`run-qemu.sh` uses `qemu-system-aarch64` with hvf (macOS) or kvm (Linux),
edk2 UEFI firmware, a virtio-scsi CD-ROM, virtio-gpu (`virtio-gpu-gl-pci`
with the GPU-enabled QEMU), a USB keyboard and tablet on an xHCI controller
(the `virt` machine has no input devices of its own), the persistent disk
on virtio-blk, virtio-rng, and user networking with SSH on
`localhost:2222` (`ssh -p 2222 ubuntu@localhost`). On Apple Silicon it
takes the QEMU in `dist/qemu-macos-arm64` when it's there (see below),
otherwise the one on `PATH`.

When that QEMU has them (the one from `qemu/build.sh` and Homebrew's do),
the guest also gets the following. When it doesn't, run-qemu.sh says
what's missing and boots without it:

- **Sound**: `virtio-sound`, played through CoreAudio on macOS, or
  PipeWire, PulseAudio or ALSA on Linux. In the guest it's an ordinary
  sound card for PipeWire. Output only on macOS, because QEMU's CoreAudio
  can't record. `--no-audio` turns it off.
- **Clipboard**: shared both ways with the QEMU window. QEMU's own SPICE
  agent channel (`qemu-vdagent`) talks to the guest's `spice-vdagent`.
  That runs on Xwayland, and Mutter bridges its clipboard to the Wayland
  one. Not with `--headless`.
- **Shared folder**: `--shared-folder PATH` shares a host folder over
  9p, read/write. In the guest,
  [live-shared-folder.service](overlay/usr/local/sbin/live-shared-folder)
  mounts it in `/media/<the folder's name>`, which Files shows in its
  sidebar. The 9p files carry the host's owner (uid 501 on a Mac), so the
  raw mount stays private, and bindfs shows the folder as the desktop
  user's: the one the welcome app created, or `ubuntu` before that. Every
  user can read and write it, whatever the host's permissions say (a
  Mac's home folders are 700). What the guest writes lands on the host as
  the user running QEMU.

It keeps its state in `dist/` (`~/.local/share/try-ubuntu/dist` when
started by install.sh):

| File | |
|---|---|
| `persist.qcow2` | the persistent disk (sparse, 32G at most) |
| `persist.qcow2.iso` | checksum of the ISO the disk belongs to; when the ISO changes, the disk is moved aside to `persist-<date>.qcow2` |
| `efivars.fd` | UEFI variables (boot entries) |
| `serial.log` | the guest's serial console output of the last boot |
| `.kernel-<iso>/` | kernel, initramfs and `limine.conf` extracted from the ISO for nested virtualization, refreshed when the ISO changes |

| Option | |
|---|---|
| `--arch arm\|x86` | the ISO's architecture (default: from its name, `ubuntu-live-amd64*` being x86). x86 runs in `qemu-system-x86_64` on a q35 machine with OVMF: kvm on an x86 Linux host, hvf on an Intel Mac, emulated elsewhere. Its persistent disk and UEFI variables are `persist-amd64.qcow2` and `efivars-amd64.fd` |
| *(none)* | the ISO in a Cocoa window. With `dist/qemu-macos-arm64`, the desktop renders on the Mac's GPU (virtio-gpu-gl) and the guest has `/dev/kvm` where the Mac allows it; with any other QEMU, it renders in software (llvmpipe) on a virtio-gpu |
| `--lang LOCALE` | language of the live session, e.g. `it_IT` or `de` (default: the host's, see below) |
| `--vnc :1` | graphics over VNC at `127.0.0.1:5901` instead of a window (software rendering) |
| `--no-gpu` | software rendering (llvmpipe) even with the GPU-enabled QEMU |
| `--no-nested` | no virtualization extensions in the guest, and the Limine menu back (with nested virtualization the kernel boots directly, see below) |
| `--qemu PATH` | the `qemu-system-aarch64` to use |
| `--headless` | no graphics at all: login on the serial console |
| `--serial` | with a window, attach the serial console to the terminal instead of the window's text console |
| `--persist[=FILE]` | the persistent qcow2 disk, **on by default** (`dist/persist.qcow2`, 32G, created on first use; replaced by a new one, the old one kept, when the ISO changes) |
| `--no-persist` | RAM only: everything is lost at shutdown |
| `--efivars FILE` | UEFI variable store (default `dist/efivars.fd`); give each VM running at the same time its own |
| `--shared-folder PATH` | share a host folder with the guest, read/write, in `/media/<name>` (see above) |
| `--no-audio` | no sound device |
| `--mem`, `--cpus`, `--ssh`, `--iso` | RAM in MiB (default: a third of the host's, at least 4096), vCPUs (default: half of the host's), SSH port, ISO path |
| `-- ARGS…` | extra arguments passed straight to QEMU (e.g. `-- -monitor tcp:127.0.0.1:4444,server,nowait`) |

With a window the terminal stays quiet: the guest's serial console is
attached to it only with `--headless` or `--serial`, multiplexed with the
monitor (`Ctrl-A X` quits QEMU, `Ctrl-A C` opens the monitor). Otherwise
it's a text console in the window itself: **Ctrl-Opt-2** (or the View
menu) shows it, Ctrl-Opt-1 goes back to the desktop, and the same keys
work over VNC. It has a login prompt (`ttyAMA0`) and the kernel's
messages, so when the desktop doesn't come up (the window says *Display
output is not active*) you can still log in and look around, e.g.
`journalctl -b -p err`. Either way, everything the serial console prints
is logged to `dist/serial.log`, overwritten at every boot.

QEMU runs with `-boot menu=on,splash-time=0`. edk2 takes its boot timeout
from QEMU, so instead of waiting ~5 s on the TianoCore logo it starts Limine
right away (~0.6 s). Limine keeps its own menu and timeout.

### QEMU for Apple Silicon

Homebrew's QEMU has no virglrenderer and its Cocoa window has no OpenGL,
so the guest only gets a framebuffer and GNOME renders in software.
[qemu/build.sh](qemu/build.sh) builds one that has both, following
[Try Omarchy](https://github.com/omacom/try-omarchy)'s runtime:

- **QEMU 11.1.1**, `aarch64-softmmu` only, HVF only (no TCG), with the
  Cocoa display, OpenGL, virglrenderer and slirp, plus `qemu-img`. It also
  has CoreAudio (`virtio-sound`), 9p (`--shared-folder`) and
  `qemu-vdagent` (the shared clipboard, built against spice-protocol's
  headers). There's no VNC server
- **GPU**: the guest's Mesa virgl driver → `virtio-gpu-gl-pci` →
  **virglrenderer** 1.3.0 (with startergo's macOS patches) → **ANGLE**
  (OpenGL ES) → **Metal**, and the Cocoa window shows the result as a
  texture (`-display cocoa,gl=es`). The guest resolution follows the
  window, HiDPI included
- **nested virtualization**: on macOS 26 with an M3 or newer, run-qemu.sh
  starts the guest at EL2 with Hypervisor.framework's GICv3
  (`virtualization=on`, `kernel-irqchip=on`), after checking with a tiny
  throwaway VM that the Mac supports it. The guest then has `/dev/kvm`, for
  VMs inside the live session. Elsewhere it boots as before. At EL2 the
  firmware's timer never fires under HVF, so edk2 and Limine hang on
  anything that waits (Limine's countdown stays at 5): with nested
  virtualization, run-qemu.sh takes the kernel, the initramfs and the
  default entry's command line from the ISO and has QEMU load them, with no
  Limine menu. Use `--no-nested` to get the menu (e.g. to boot a snapshot).
  A reboot from inside the guest would crash edk2 (once Linux has used
  EL2, HVF doesn't reset all of it: a stack overflow in `ArmCpuDxe`), so
  with nested virtualization it makes QEMU quit and run-qemu.sh starts it
  again: the window closes and reopens
- **memory**: free-page reporting (`virtio-balloon`) hands the RAM the guest
  frees back to macOS (it needs the HVF patch, so run-qemu.sh enables it
  only with this QEMU, and always with kvm)
- the patches in [qemu/patches](qemu/patches/README.md): Cocoa GL, the GPU
  fixes, HVF fixes (among them a crash on writes to the UEFI flash)

Everything it downloads is pinned by sha256: the QEMU, virglrenderer,
dtc, keycodemapdb and spice-protocol sources, ANGLE and libepoxy (startergo's bottles), and
GLib, gettext, PCRE2, Pixman and libslirp as Homebrew's arm64_sequoia
bottles, fetched straight from ghcr.io. It needs only Xcode's command line
tools, `python3` and `pkg-config`, and takes ~10 minutes. The result, in
`dist/qemu-macos-arm64` (~170 MB, most of it the edk2 firmware; 11 MB as
a tarball), is self-contained: the libraries are
relocated next to the binaries and everything is ad-hoc signed, QEMU with
the `com.apple.security.hypervisor` entitlement. It runs on macOS 15 or
newer. Releases ship it as `qemu-macos-arm64.tar.gz`, which install.sh
downloads.

### The host's language

`run-qemu.sh` reads the language from the shell's locale (`LC_ALL`, then
`LC_MESSAGES`, then `LANG`). If none is set, or it's `C`/`POSIX` (as in
some macOS terminals), it uses macOS's own (`defaults read -g
AppleLocale`). `--lang` overrides both. It passes the locale name (e.g.
`it_IT`) to the guest through QEMU's fw_cfg, as
`opt/org.ubuntu.live/locale`.

In the guest,
[live-locale.service](overlay/etc/systemd/system/live-locale.service)
runs before GDM. It loads `qemu_fw_cfg`, reads the locale and picks the
image's locale for it: the same one, or another of the same language
(`en_GB` → `en_US`). It then sets it as the system language
(`/etc/default/locale`) and as the live user's language in
AccountsService. Languages the image doesn't have keep English. The
welcome app preselects that language, and with it that language's
keyboard layout. Once the welcome app has created your user, the
service no longer runs: your user's language is the one you chose there.

## The desktop

[scripts/desktop-gnome.sh](scripts/desktop-gnome.sh) sets up a minimal
GNOME 51 the way Ubuntu's desktop looks, all without recommends:

| | |
|---|---|
| Shell | `gnome-shell`, `gnome-session` (the vanilla GNOME session, not Ubuntu's), `gdm3`, `xdg-desktop-portal-gnome`, NetworkManager |
| Apps | Settings, Nautilus, Brave Origin, **ghostty** (the default terminal: Ctrl+Alt+T and Nautilus' "Open in Terminal", through `xdg-terminal-exec`), **Ptyxis** (Ubuntu's terminal, for when Ghostty can't start, see below), **Calculator**, **Papers** (PDF), **Fonts**, **Text Editor**, **GNOME Software** (apt, through PackageKit), **Disks** (`gnome-disk-utility`, with udisks2), **Resources**, **Extensions** (`gnome-extensions-app`) |
| Icons | **Yaru**, and the variant follows the accent color and the style, as on Ubuntu (see below) |
| Extensions | **Dash to Dock**, set up as Ubuntu's dash: a full-height panel on the left with Files, Brave Origin, Ghostty and Software, "Show Apps" at the bottom, trash and mounted drives. **Kiwi Menu**, with the Ubuntu logo. **Caffeine** (on from login: no screen blanking or automatic suspend), **Vitals** (average temperature, memory, network speed), **Rounded Corners** (6 px screen corners) |
| Wallpaper | one of Ubuntu's stock wallpapers (`ubuntu-wallpapers`, which Ubuntu's gnome-shell depends on), picked at random at each build by [pick-wallpaper.py](scripts/pick-wallpaper.py), with its dark variant if it has one. The build log names the pick; the others stay available in Settings › Appearance |

- **First boot and the welcome app**: GDM logs the live user
  (`ubuntu`) in automatically, and the session starts
  [live-welcome](overlay/usr/local/bin/live-welcome), a GTK 4 /
  libadwaita draft. Its pages:
  1. **Language**, preselected from the host's (see
     [The host's language](#the-hosts-language)). The UI speaks English
     and Italian and switches right away. The other languages fall back to
     English for now.
  2. **Keyboard layout**, with a test field. The live session switches to
     it as you pick.
  3. **Account**: full name, username (suggested from the name), password
     twice, email and the computer's name, with validation. The name is
     suggested as `ubuntu-<vm|laptop|desktop>-<username>`
     (`systemd-detect-virt`, then the DMI chassis type), e.g.
     `ubuntu-laptop-anna`, and setup-user sets it (`hostnamectl`,
     `/etc/hosts`).
  4. **Picture**: an avatar in one of DiceBear's CC0 styles (Open Peeps,
     Lorelei, Notionists, Pixel Art, Thumbs), random at first. Arrows change
     each part (hair, eyes, beard…) and swatches its colors. Or you can
     switch it off and keep your initials. The app composes the avatars
     itself ([avatars.py](overlay/usr/local/lib/live-welcome/avatars.py),
     librsvg), from the style packages that
     [dicebear.py](scripts/dicebear.py) turns into JSON at build time, so
     it works offline and sends nothing anywhere.
  5. **Appearance**: light or dark, and one of GNOME's nine accent colors.
     The live session previews the choice.
  6. **Summary**, then **"Start using Ubuntu"**.
  
  That button runs [setup-user](overlay/usr/local/lib/live-welcome/setup-user)
  through `pkexec`. A [polkit policy](overlay/usr/share/polkit-1/actions/org.ubuntu.live-welcome.policy)
  lets the active session run it without a password, and it works only
  once (`/var/lib/live-welcome/done`). It:
  - creates the user (zsh, groups `sudo video render input`, subuids for
    podman)
  - sets the system language and keyboard, which GDM uses too
  - compiles the user's GNOME settings into their dconf database: style,
    accent, Yaru variant, input source and region. The first login is
    already themed
  - installs the picture (AccountsService: GDM, the Shell and Settings
    show it)
  - writes `~/.gitconfig` with `user.name` / `user.email`
  - starts Cloud Config at the first login, which then opens Cloud Backup (see below)
  - retires the live user: no autologin, password locked, out of the admin
    groups and without passwordless sudo right away; then
    `live-retire-user.service` deletes it, home included, as soon as its
    session has logged out (or at the next boot, before GDM). snapper's
    `ALLOW_USERS` goes to the new user
  
  The session then logs out to GDM, where only the new user is listed.
- **Cloud Config** ([live-cloud-config](overlay/usr/local/bin/live-cloud-config),
  icon [assets/cloud-config-app.svg](assets/cloud-config-app.svg)) opens by
  itself at the new user's first login, in three steps:
  1. **The network**
     ([netsetup.py](overlay/usr/local/lib/live-backup/netsetup.py)), when
     NetworkManager says there's none: plug in a cable when the computer
     has a wired port, or pick a Wi-Fi network and type its password
     (`nmcli`). It goes on by itself once the network is up.
  2. **Tailscale**, explained in two lines, to add the computer to your
     tailnet: `pkexec tailscale up --operator=<you>` opens the sign-in
     page in the browser, and the app waits for it. Skipped when the
     computer is already on a tailnet.
  3. **Your clouds**: Google Drive, OneDrive, Dropbox, Nextcloud and
     iCloud Drive, each connected or with a Connect button. A connected one
     is an account
     ([accounts.py](overlay/usr/local/lib/live-backup/accounts.py)): an
     rclone remote of its own, `acct-<id>`, holding its sign-in, listed in
     `~/.config/live-backup/accounts.json`. It shows up in Files (see
     below), and Cloud Backup can keep the backups on it. Its menu opens it
     in Files or disconnects it: it leaves Files and its sign-in is
     forgotten, nothing is deleted from the cloud. The one that holds the
     backups can't be disconnected until they go elsewhere. "Show the
     clouds in Files" turns all the mounts off and on.

  "Continue with the Backups" then opens Cloud Backup. Afterwards, Cloud
  Config is in the app grid. It signs in to each cloud by itself
  ([providers.py](overlay/usr/local/lib/live-backup/providers.py)), without
  GNOME Online Accounts:
  - **Google Drive, OneDrive, Dropbox**: in the browser, with rclone's own
    sign-in (`rclone authorize`). rclone keeps and renews the token. By
    default it uses rclone's OAuth clients, which every rclone user
    shares: Google often turns them away for a while
    (`rateLimitExceeded`, which the app explains in plain words). For an
    image to hand out, build it with its own clients:
    `./build.sh --oauth-clients clients.json`, with
    `{"drive": {"client_id": "…", "client_secret": "…"}}` (and/or
    `onedrive`, `dropbox`): a "Desktop app" OAuth client of a Google Cloud
    project with the Drive API on, as
    [rclone explains](https://rclone.org/drive/#making-your-own-client-id).
    It lands in `/etc/live-backup/oauth-clients.json`.
  - **Nextcloud**: you type the server's address, then approve in the
    browser (Login Flow v2, as Nextcloud's own clients do). Nextcloud
    gives an app password just for the backups, which you can revoke in
    its security settings.
  - **iCloud Drive**: Apple ID, password and the code sent by text
    message, through [icloud-linux](https://github.com/antoniopicone/icloud-linux)
    (`icloudctl`, built into the image by
    [build-icloud-linux.sh](scripts/build-icloud-linux.sh)), which then
    mounts iCloud Drive in `~/iCloud` (in the Files sidebar too). The
    password isn't kept: when Apple asks to sign in again, every few
    weeks, a backup fails with a notification.
- **Cloud Backup** ([live-backup](overlay/usr/local/bin/live-backup)) asks
  where to keep your data, documents and preferences safe:
  - **one of your clouds**, those Cloud Config connected. The backups use
    that account's sign-in: their rclone remote (`cloud:`) is an alias of
    the account's (`acct-<id>:`), so there's one token, which rclone
    renews in the account's own section. With no cloud connected, a button
    opens Cloud Config.
  - **Samba**: server, share (or picked from the list), user and password,
    or none for a guest share.
  - **SFTP**: server, port, user, and a password or a key file (with its
    passphrase). The first time, the app shows the server's key
    fingerprints and asks before trusting them.

  The settings are in `~/.config/live-backup` (readable only by you):
  rclone's remote, with passwords obscured the rclone way, and the trusted
  SSH host keys. "Set Up Later" skips it all; the app stays in the app
  grid.
  - You pick the folder in a tree of the destination's folders (and can
    create one). The backups go in a new folder inside it, with a random
    name. Backups already in the chosen folder (an earlier install) are
    opened with their recovery key.
  - **End-to-end encryption, with a recovery key**
    ([cloud.py](overlay/usr/local/lib/live-backup/cloud.py)): the app makes
    a random key (160 bits, 8 groups of 4 characters) and shows it once,
    to copy, save or print. It checks that it was kept by asking for two
    of its groups, and keeps it in the GNOME keyring for the hourly
    backups. Two layers, with keys derived from it:
    - restic encrypts the content, the file names and the layout of the
      home folder;
    - under it, rclone's crypt encrypts the names of restic's own files.

    So the destination holds one folder with a random neutral name, and in
    it only encrypted names: nothing says it's a backup, restic, Ubuntu, or
    whose. The key never goes to a file (crypt's passwords reach rclone
    through the environment). Without it nobody, the user included, can
    open the backups. On another computer, or after reinstalling, the app
    recognises the encrypted folders in the chosen folder and opens them
    with the key. Sizes and the times of the backups stay visible.
  - Its icon is [assets/backup-app.svg](assets/backup-app.svg), installed
    as PNGs rendered by librsvg (GTK draws the SVG's shadows as a grey
    square).
  - **In the top bar**, a GNOME Shell extension
    ([cloud-backup@ubuntu-live](overlay/usr/share/gnome-shell/extensions/cloud-backup@ubuntu-live/extension.js),
    on by default) shows the backups' state: a plain cloud, the cloud with
    an arrow going up while one runs, with "!" when the last one failed. Its menu has the
    backup in progress (percentage, files, size, time left: run-backup
    writes restic's progress to `~/.local/state/live-backup/progress.json`
    every second) or the last one, "Back Up Now" and "Open Cloud Backup".
  - **In Files**: every cloud of Cloud Config is mounted with rclone in
    the home folder (`~/Google Drive`, `~/Nextcloud`…) by a systemd user
    unit at every login
    ([live-cloud@.service](overlay/etc/systemd/user/live-cloud@.service),
    [mount.py](overlay/usr/local/lib/live-backup/mount.py)), with its place
    in the sidebar (Files lists a mount in the home folder by itself),
    with a cloud for icon (see the Nautilus patch below). So is Cloud
    Backup's own Samba or SFTP destination (`~/SFTP (anna@server)`,
    [live-cloud-mount.service](overlay/etc/systemd/user/live-cloud-mount.service)),
    with a network folder.
    Files are fetched when opened and cached in `~/.cache/rclone`. The
    backups' encrypted folder is hidden from the mount it's on, and
    localsearch is kept out of every mount (it would download the whole
    drive). iCloud Drive is icloud-linux's own mount, `~/iCloud`.
  - The browser page after signing in to Google Drive, OneDrive or Dropbox
    is the app's (`rclone authorize --template`): its icon, the outcome in
    the session's language, light or dark.
  - [run-backup](overlay/usr/local/lib/live-backup/run-backup), started
    by a systemd user timer every hour while you're logged in (a missed
    one runs at the next login), backs up your home folder (the `@home`
    subvolume's, `--one-file-system`), without caches, Trash, container
    images and `~/iCloud`
    ([excludes](overlay/usr/local/share/live-backup/excludes)). It keeps
    24 hourly, 7 daily, 4 weekly, 12 monthly and 3 yearly versions (pruned
    once a day). restic reaches every destination through rclone, the
    upstream 1.75 build (Ubuntu 26.04's 1.60 hangs reading from SFTP, so a
    restore would never finish). For iCloud it writes into the mount and
    waits for icloudd to upload. A failure is
    a notification. The app shows the last backup, and can start one,
    change the folder or stop them.
  - **Restoring** ([restore.py](overlay/usr/local/lib/live-backup/restore.py)):
    when the folder picked at setup already has backups (an earlier
    install, another computer: the user name may differ), the app offers to
    bring the newest one back before the hourly backups start. It lists
    what comes back, by type (documents, pictures, videos, music, archives,
    code, other files, app settings) with how many, and what it replaces:
    what is on this computer too in another version, by what it is
    (terminal settings, GNOME settings, profile picture, shell, Git, SSH
    keys, browser, extensions, other apps). Nothing is deleted: files that
    are only here stay. Never restored: the keyring (sealed with the old
    password), the backups' own settings, the iCloud session, caches.
    GNOME's settings are loaded into the running session (`dconf load`),
    and the profile picture, which run-backup copies into the backup from
    AccountsService, is set back through AccountsService. The status page
    can restore the newest backup at any time.
  - **The apps come back too**
    ([apps.py](overlay/usr/local/lib/live-backup/apps.py)). Before each
    backup, run-backup writes the list of the user's apps into
    `~/.local/share/live-backup/apps.json`, so it's in the backup:
    - the Flatpak apps, with their remote and installation (system or user)
    - the apt packages installed by hand that the image doesn't have
      (`apt-mark showmanual`, less the image's own list, which the build
      writes to `/usr/local/share/live-backup/image-packages`)

    After a restore, when some of them aren't installed, the app offers to
    install them again. The Flatpak apps come from their remotes. The
    packages go through
    [install-packages](overlay/usr/local/lib/live-backup/install-packages),
    as root through `pkexec` (so the user's password): it refreshes the
    package lists and skips what the archive doesn't have, e.g. a package
    from a repository added by hand. What couldn't be installed is listed.

- **Brave Origin** is the browser: Brave with its Shields but without
  what funds Brave (Rewards, Wallet, VPN, Leo AI, News, Talk, Tor,
  Playlist, Speedreader…) and without the usage ping, crash reports and
  analytics. It's free on Linux, and comes from Brave's own repository.
  - **language and style**: its UI follows `LANG`, like the rest of the
    session (the build keeps only the image's languages), and by default
    its light or dark mode is the device's.
  - **ads and trackers**: Brave's own Shields block them, so no extension
    is needed.
  - **its repository, and no other**: brave-origin's maintainer scripts
    come from Chrome's. Unless `/etc/default/brave-origin` says
    `repo_add_once="false"`, its postinst adds a repository of its own, and
    the one in today's package is Google Chrome's (`dl.google.com`, with
    Google's key). The build writes that file before the install and fails
    if any Google repository or any key in `trusted.gpg.d` shows up. The
    `.sources` file has the name and `Signed-By` that `brave-keyring`
    expects. With any other name, that package would put Brave's keys in
    `trusted.gpg.d`, trusted for every repository.
- **Ghostty, or Ptyxis**: `/usr/bin/ghostty` is
  [a wrapper](overlay/usr/local/bin/ghostty). When Ghostty fails within its
  first 10 seconds (no usable OpenGL, a broken config…), Ptyxis opens
  instead, with the same working directory and command, and a
  notification says so. `xdg-terminals.list` names Ptyxis second, for
  when Ghostty isn't installed at all.
- **Yaru ↔ accent color**: [yaru-accent-sync](overlay/usr/local/bin/yaru-accent-sync)
  runs in every session (from `/etc/xdg/autostart`). It follows
  Settings › Appearance and sets `Yaru-<variant>[-dark]` with Ubuntu's own
  mapping (from Ubuntu's gnome-shell `getYaruVariantFromAccent()`):

  | Accent | Yaru variant |
  |---|---|
  | blue | `blue` |
  | teal | `prussiangreen` |
  | green | `olive` |
  | yellow | `yellow` |
  | orange | plain `Yaru` |
  | red | `red` |
  | pink | `magenta` |
  | purple | `purple` |
  | slate | `sage` |

  The `-dark` suffix is added in dark style.
- **Extensions**: pinned (`EXTENSIONS` in desktop-gnome.sh), checked with
  sha256 and installed system-wide. The build fails if one doesn't declare
  GNOME 51. Their schemas move to the system schema directory, so the
  gschema override can configure them. Their own `schemas/` folder is
  removed: GNOME Shell would look for a `gschemas.compiled` there, which
  the zips no longer ship.
  - Dash to Dock, Kiwi Menu and Vitals: their GNOME 51 release on
    extensions.gnome.org (`version_tag`)
  - Caffeine: a commit of its `master`, which supports GNOME 51 while its
    last release stops at 50. Its translations come as `.po` files and are
    compiled at build time
  - Rounded Corners: its last release declares up to GNOME 50. It works
    unchanged on GNOME 51.0 (tested), so the build adds 51 to its
    `metadata.json` (`force`)
- **Autostart**: GNOME 51's gnome-session skips autostart entries that set
  `X-GNOME-Autostart-Phase` (it treats them as session services), so these
  entries don't set it.
- **GNOME 51 on 26.04**: Ubuntu 26.04 ships GNOME 50, and GNOME 51 is only
  in 26.10 (stonking). Installing 26.10's binaries on 26.04 would pull in
  ~280 packages built for 26.10. Instead,
  [scripts/build-gnome.sh](scripts/build-gnome.sh) rebuilds 26.10's Ubuntu
  **source** packages against 26.04. That's 21 sources: the GNOME 51 core
  (gnome-shell, mutter, gdm3, gnome-session, gnome-settings-daemon,
  gnome-control-center, nautilus, xdg-desktop-portal-gnome,
  gsettings-desktop-schemas, gnome-desktop, and the Extensions app, since
  26.04's pins gnome-shell to its exact 50.x version) and what it needs newer at
  build time (glib 2.90, gtk4 4.24, pango 1.58, gjs 1.90, wayland +
  wayland-protocols, accountsservice, gexiv2, ubuntu-insights, ibus, which
  gtk4 4.24 `Breaks` in 26.04's version, and debhelper 14 for the build
  only). libc, systemd, Mesa, mozjs and the
  rest stay 26.04's.
  - apt downloads the sources and checks them against the signed 26.10
    archive. Each gets a `~26.04.1` changelog entry, so its version sorts
    above 26.04's and below 26.10's.
  - They build without tests, docs or LTO. Each package goes into a local
    apt repository (`/cache/gnome-repo` in the podman volume), and the next
    ones build against it.
  - Local fixes in [patches/gnome/](patches/gnome/)`<source>/` go on top
    of the package's own patches:
    - [gdm3](patches/gnome/gdm3/fix-fallback-session-double-free.patch):
      Ubuntu's `prefer_ubuntu_session_fallback.patch` frees the fallback
      session name twice when there is no `ubuntu` session, so without the
      fix gdm aborts as soon as someone starts to log in on an image that
      only has the vanilla GNOME session.
    - [nautilus](patches/gnome/nautilus/cloud-mount-icon.patch): gvfs gives
      every FUSE mount in the home folder a removable drive for icon. The
      sidebar shows a cloud
      ([live-cloud-symbolic](overlay/usr/local/share/icons/hicolor/scalable/apps/live-cloud-symbolic.svg),
      as in the mockups) for the clouds' mounts instead: rclone's with the
      device `live-cloud:<id>` (`--devname`), and icloud-linux's
      (`fuse.icloud`). rclone's
      other mounts (Samba, SFTP) get a network folder.
  - The rootfs installs from that repository, which is mounted only for the
    build, and the build fails unless the core is at version 51.
  - It takes ~1–2 hours the first time. After that, it's skipped for as long
    as 26.10's source versions stay the same.
- **Settings**: gschema overrides set the defaults for GDM and every user:
  - dark style, the blue accent and Adwaita Sans
  - the keyboard layout
  - the wallpaper
  - the Yaru icons
  - the enabled extensions
  - the dash favorites (Nautilus, Brave Origin, Ghostty, Software, Resources)
  - traditional scrolling (not "natural"), for mice and touchpads
  - the extensions' settings
  - no welcome tour

  AccountsService preselects the `gnome` session.
- **GNOME Software's catalogue**: the image ships without apt's package
  lists, so without the app catalogue (DEP-11, read by `appstream`) that
  comes with them. At every boot, once the network is up,
  [live-software-refresh](overlay/usr/local/sbin/live-software-refresh)
  runs `apt-get update` and `flatpak update --appstream`. Without the
  network, it tries again every minute.
- **Spinners**: when the desktop renders in software (a VM without GPU
  acceleration), GNOME Shell turns animations off, and libadwaita 1.9's
  `Adw.Spinner` stays frozen on its first frame even with animations
  forced back on in the app. The live system's apps (welcome, Cloud
  Backup, Previous Versions) use
  [livespinner](overlay/usr/local/lib/live-common/livespinner.py) instead,
  which draws itself on every frame tick.
- **Default browser**: setup-user writes the system's default apps (Brave
  Origin) into the new user's `~/.config/mimeapps.list`. A restore drops
  the lines of the backup's `mimeapps.list` that name apps not installed
  here, such as an older image's browser, so the system's defaults apply.
- **Network**: NetworkManager manages every device through
  [overlay/etc/netplan](overlay/etc/netplan/01-network-manager-all.yaml),
  as on Ubuntu Desktop, so the network menu and Settings work.
  systemd-networkd is off.
- **Rendering**: with the QEMU from `qemu/build.sh`, GNOME Shell and the
  apps render with Mesa's virgl driver, on the host's GPU. With any other
  QEMU, GNOME Shell uses llvmpipe on a display-only virtio-gpu. Neither
  needs a patch.
- **ufw** is on at boot. It denies incoming traffic except SSH (22/tcp)
  and mDNS (5353/udp).

## Releases

Pushing a `v*` tag runs [.github/workflows/release.yml](.github/workflows/release.yml):

```bash
git tag v1.0.0 && git push origin v1.0.0
```

- It builds the ISOs with `./build.sh --xkb us`, each on a native runner:
  arm64 on `ubuntu-24.04-arm`, amd64 (`--arch x86`) on `ubuntu-24.04`. They
  use rootful podman, since the ISO step needs loop devices. These are the
  QEMU flavour. The real-computer one (`--hardware`) is built locally by
  `install.sh --on-usb`.
- The GNOME 51 backport (`/cache/gnome-repo`) is kept in the Actions cache,
  one per architecture.
  Only the first build takes hours: later ones rebuild just the packages
  that changed (a new 26.10 version, different local patches, one added to
  `build-gnome.sh`). To rebuild everything, e.g. after changing the
  `Containerfile` or the build flags, delete the `gnome-repo-*` caches
  (Actions → Caches).
- It builds `qemu-macos-arm64.tar.gz` with `./qemu/build.sh` on a
  `macos-15` runner, caching the downloads.
- It publishes a release with `ubuntu-live-arm64.iso`, `ubuntu-live-amd64.iso`,
  `qemu-macos-arm64.tar.gz` and `SHA256SUMS`.
  A release asset can be at most 2 GiB, and the build fails if the ISO is
  bigger. [install.sh](install.sh) downloads from there.

## Limitations

- The backported GNOME 51 packages (and glib, gtk4, pango…) get no
  updates from 26.04. Rebuilding picks up whatever 26.10 has at that point.
- With `--no-persist`, everything lives in RAM.
- On real computers: UEFI only (no legacy BIOS boot), with Secure Boot off.
  An installed system's Limine menu has its kernels but not snapper's
  snapshots: booting a snapshot is for the live system.
- Installing into free space needs a GPT disk. An MBR disk can only be
  installed on whole.
- The welcome app is a first draft:
  - its UI only speaks English and Italian
  - it offers six languages and ten keyboard layouts
  - it has no timezone page
- The host's language reaches the guest only under QEMU (`run-qemu.sh`);
  on other hypervisors or hardware the live session starts in English.
- The QEMU flavour (the releases' ISOs) has no sound drivers other than
  virtio-sound and no firmware for real hardware (Wi-Fi, non-virtio
  GPUs): it's aimed at VMs. For real computers, `build.sh --hardware`
  (what `install.sh --on-usb` builds).
- With the QEMU from `qemu/build.sh`, sound is output only (no
  microphone), and `--vnc` doesn't work (no VNC server in it): use
  Homebrew's with `--qemu`.
- apfs-fuse only reads APFS: Mac disks can't be written to.
- The Microsoft core fonts (Arial, Times New Roman…) aren't included: their
  license allows redistributing only the original installers. Liberation,
  Carlito and Caladea take their place with the same metrics; `sudo apt
  install ttf-mscorefonts-installer` (multiverse) fetches the real ones.
- The `ubuntu` / `ubuntu` credentials and passwordless sudo are meant for a
  live system. Once your user exists, the welcome app locks them and the
  `ubuntu` user is deleted after the logout. Until then they work, so
  change them in `build-rootfs.sh` (`LIVE_USER`, `LIVE_PASSWORD`) before
  distributing the ISO.
