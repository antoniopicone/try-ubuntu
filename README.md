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
`--rebuild`:

```bash
curl -fsSL https://raw.githubusercontent.com/antoniopicone/try-ubuntu/main/install.sh | sh -s -- --lang de_DE --no-persist
curl -fsSL https://raw.githubusercontent.com/antoniopicone/try-ubuntu/main/install.sh | sh -s -- --rebuild
```

- **Which ISO**: the one for the host's CPU, when the release has it. Right
  now releases only have `ubuntu-live-arm64.iso`: it runs with hardware
  acceleration on Apple Silicon (hvf) and arm64 Linux (kvm), and emulated
  (TCG, slow) on x86_64.
- **QEMU**: on Apple Silicon, the release's own build (see
  [QEMU for Apple Silicon](#qemu-for-apple-silicon)), with GPU acceleration
  and nested virtualization; nothing gets installed system-wide. On an Intel
  Mac it's Homebrew's (`brew install qemu`), and on Linux it's installed with
  apt (Debian, Ubuntu), dnf (Fedora) or pacman (Arch), together with the
  aarch64 UEFI firmware (this uses sudo).
- **Files**: the ISO, the persistent disk and `run-qemu.sh` go in
  `~/.local/share/try-ubuntu` (set `TRY_UBUNTU_DIR` to change it). The ISO
  is checked against the release's `SHA256SUMS`, and an interrupted
  download resumes.
- **Updates**: running it again boots the same ISO, or downloads the newer
  one when there's a new release. The old persistent disk only works with
  its own ISO, so it's moved aside to `persist-<tag>.qcow2`.
- **Starting over**: `--rebuild` deletes what the script downloaded and the
  caches (the ISO, partial downloads, QEMU for Apple Silicon, `run-qemu.sh`,
  and the kernel `run-qemu.sh` extracts from the ISO for nested
  virtualization), then downloads them again from the latest release. The
  persistent disks and the UEFI variables (`efivars.fd`) stay. A persistent
  disk is still moved aside when the latest release isn't the one it was
  made with. Homebrew's or the distribution's QEMU isn't touched.

## Build it

```bash
./build.sh --xkb it          # → dist/ubuntu-live-arm64.iso (~1.4 GB)
./qemu/build.sh              # macOS: → dist/qemu-macos-arm64 (optional, GPU + nested virtualization)
./run-qemu.sh                # boot it in a window (--serial: serial console in the terminal too)
./run-qemu.sh --lang de_DE   # boot in German instead of the host's language
./run-qemu.sh --no-persist   # RAM only (by default changes and snapshots go to a persistent disk)
```

`run-qemu.sh` attaches a persistent disk by default (see
[How the live btrfs works](#how-the-live-btrfs-works)), so what you set up
survives reboots.

On first boot the live user (`ubuntu`) logs in by itself and the welcome
app takes over: it creates your user and logs out to GDM (see
[The desktop](#the-desktop)).

## What's in it

| | |
|---|---|
| Base | `debootstrap --variant=minbase` resolute with a hand-picked package set (no `ubuntu-minimal` or console-setup): openssh, sudo |
| Kernel | `linux-image-virtual` (7.0), pruned to the modules a VM needs, with no firmware. initramfs-tools with zstd -19 |
| Boot | **Limine** 11 (arm64 UEFI), with a menu to boot snapper snapshots, and Plymouth with the `spinner` theme (GNOME's). The ISO is hybrid (El Torito EFI + appended GPT ESP), so it also boots when written with `dd` to a USB stick |
| Filesystem | btrfs with the subvolumes `@` → `/`, `@home` → `/home`, `@var` → `/var`, `@snapshots` → `/.snapshots` (flat layout, `compress=zstd:1`). **snapper** manages `/`; snapshot #1 is the image as built |
| Desktop | a minimal **GNOME 51**: Shell, Settings, the vanilla GNOME session, GDM (see [The desktop](#the-desktop)) |
| Theme | dark style with GNOME's blue accent, Adwaita Sans, Yaru icons, and **one of Ubuntu's stock wallpapers, picked at random at each build** |
| Apps | **ghostty** (Hack Nerd Font Mono, Catppuccin Mocha), **Nautilus** (with *Open in Ghostty*), **Chromium** (in the desktop's language and light/dark style, with uBlock Origin Lite), GNOME Software (with **Flatpak** and Flathub), Disks, Resources, Extensions |
| Fonts | Adwaita Sans; Liberation, **Carlito** and **Caladea** (metric-compatible with Arial/Times New Roman/Courier New and Calibri/Cambria, so Office documents keep their layout); JetBrains Mono; **Hack Nerd Font Mono** |
| Network | NetworkManager (via netplan, as on Ubuntu Desktop) |
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
| `ppa:xtradeb/apps` | Chromium as a .deb (Ubuntu only ships it as a snap). Pinned so it provides **only** `chromium*` | `5301FA4F…82BB6851C64F6880` |
| `pkgs.tailscale.com` | tailscale | `2596A99E…458CA832957F5868` |

These files are pinned and checked with sha256, not taken from a
repository:
- [uv](https://github.com/astral-sh/uv) (`UV_*` in build-rootfs.sh)
- [pure](https://github.com/sindresorhus/pure) (`PURE_*`)
- [Limine](https://codeberg.org/Limine/Limine) (`LIMINE_*` in
  build-iso.sh)
- the GNOME Shell extensions (`EXTENSIONS` in desktop-gnome.sh)
- [Hack Nerd Font](https://github.com/ryanoasis/nerd-fonts), the Mono
  variant only (`HACK_NERD_*` in build-rootfs.sh)
- [apfs-fuse](https://github.com/sgan81/apfs-fuse) and its lzfse
  submodule, built from source by
  [scripts/build-apfs-fuse.sh](scripts/build-apfs-fuse.sh) (it has no
  releases: a pinned commit)

### Footprint

The ISO would be much larger without these measures:

- The package set is chosen by hand (see Base above), with no
  recommends.
- dpkg path-excludes skip docs, man pages, info pages, translations and
  Qt translations ([overlay/etc/dpkg/dpkg.cfg.d](overlay/etc/dpkg/dpkg.cfg.d/01-live-excludes)).
- Kernel modules are cut down to filesystems, networking, crypto, virtio,
  USB/HID/SCSI/NVMe and the virtio-gpu DRM driver. Sound, other GPUs,
  wireless/ethernet NICs and media drivers are gone, and so is all
  firmware. The build fails if a required module was removed.
- glibc's extra charset converters (`libc-gconv-modules-extra`) are
  removed.
- Chromium keeps only the translations for the image's languages (all
  of them take ~120 MB).
- `/boot` isn't in the rootfs: the kernel and initramfs sit only on the ISO.
- Snapshot #1 shares every extent with `@`, so it costs only metadata.
- The btrfs seed uses zstd:15.

What's left is mostly needed at runtime: LLVM for Mesa's llvmpipe
(software rendering), GNOME, Chromium, GTK 4. Limine also needs the kernel
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
     ISO build, so after a rebuild it's rejected, and changes stay in RAM
     until you delete it (`rm dist/persist.qcow2`).
3. It mounts `@` (or a snapshot, see below), `@home`, `@var` and
   `@snapshots` just as an installed system would.

This means the live session runs on real btrfs, so snapshots,
`btrfs subvolume`, compression and the rest all work.

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
   apfs-fuse, cached the same way (~1 minute).
3. [scripts/build-rootfs.sh](scripts/build-rootfs.sh) builds the rootfs,
   and sources [scripts/desktop-gnome.sh](scripts/desktop-gnome.sh) for
   GNOME's packages and configuration. It:
   - runs debootstrap
   - adds the extra repositories and installs the packages and the
     [overlay/](overlay/)
   - sets up Plymouth, ufw, rootless podman, snapper, uv, zsh + pure,
     Hack Nerd Font, apfs-fuse, Flathub and the default apps
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
edk2 UEFI firmware, a virtio-scsi CD-ROM, virtio-gpu, and user networking
with SSH on `localhost:2222` (`ssh -p 2222 ubuntu@localhost`). On Apple
Silicon it takes the QEMU in `dist/qemu-macos-arm64` when it's there (see
below), otherwise the one on `PATH`.

| Option | |
|---|---|
| *(none)* | the ISO in a Cocoa window. With `dist/qemu-macos-arm64`, the desktop renders on the Mac's GPU (virtio-gpu-gl) and the guest has `/dev/kvm` where the Mac allows it; with any other QEMU, it renders in software (llvmpipe) on a virtio-gpu |
| `--lang LOCALE` | language of the live session, e.g. `it_IT` or `de` (default: the host's, see below) |
| `--vnc :1` | graphics over VNC at `127.0.0.1:5901` instead of a window (software rendering) |
| `--no-gpu` | software rendering (llvmpipe) even with the GPU-enabled QEMU |
| `--no-nested` | no virtualization extensions in the guest, and the Limine menu back (with nested virtualization the kernel boots directly, see below) |
| `--qemu PATH` | the `qemu-system-aarch64` to use |
| `--headless` | no graphics at all: login on the serial console |
| `--serial` | with a window, also attach the serial console to the terminal |
| `--persist[=FILE]` | the persistent qcow2 disk, **on by default** (`dist/persist.qcow2`, 32G, created on first use) |
| `--no-persist` | RAM only: everything is lost at shutdown |
| `--efivars FILE` | UEFI variable store (default `dist/efivars.fd`); give each VM running at the same time its own |
| `--mem`, `--cpus`, `--ssh`, `--iso` | RAM in MiB (default: a third of the host's, at least 4096), vCPUs (default: half of the host's), SSH port, ISO path |
| `-- ARGS…` | extra arguments passed straight to QEMU (e.g. `-- -monitor tcp:127.0.0.1:4444,server,nowait`) |

With a window the terminal stays quiet: the guest's serial console is
attached to it only with `--headless` or `--serial`, multiplexed with the
monitor (`Ctrl-A X` quits QEMU, `Ctrl-A C` opens the monitor).

QEMU runs with `-boot menu=on,splash-time=0`. edk2 takes its boot timeout
from QEMU, so instead of waiting ~5 s on the TianoCore logo it starts Limine
right away (~0.6 s). Limine keeps its own menu and timeout.

### QEMU for Apple Silicon

Homebrew's QEMU has no virglrenderer and its Cocoa window has no OpenGL,
so the guest only gets a framebuffer and GNOME renders in software.
[qemu/build.sh](qemu/build.sh) builds one that has both, following
[Try Omarchy](https://github.com/omacom/try-omarchy)'s runtime:

- **QEMU 11.1.1**, `aarch64-softmmu` only, HVF only (no TCG), with the
  Cocoa display, OpenGL, virglrenderer and slirp, plus `qemu-img`
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
  Limine menu. Use `--no-nested` to get the menu (e.g. to boot a snapshot)
- **memory**: free-page reporting (`virtio-balloon`) hands the RAM the guest
  frees back to macOS
- the patches in [qemu/patches](qemu/patches/README.md): Cocoa GL, the GPU
  fixes, HVF fixes (among them a crash on writes to the UEFI flash)

Everything it downloads is pinned by sha256: the QEMU, virglrenderer,
dtc and keycodemapdb sources, ANGLE and libepoxy (startergo's bottles), and
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
| Apps | Settings, Nautilus, Chromium, **ghostty** (the default terminal: Ctrl+Alt+T and Nautilus' "Open in Terminal", through `xdg-terminal-exec`), **GNOME Software** (apt, through PackageKit), **Disks** (`gnome-disk-utility`, with udisks2), **Resources**, **Extensions** (`gnome-extensions-app`) |
| Icons | **Yaru**, and the variant follows the accent color and the style, as on Ubuntu (see below) |
| Extensions | **Dash to Dock**, set up as Ubuntu's dash: a full-height panel on the left with Files, Chromium, Ghostty and Software, "Show Apps" at the bottom, trash and mounted drives. **Kiwi Menu**, with the Ubuntu logo. **Caffeine** (on from login: no screen blanking or automatic suspend), **Vitals** (average temperature, memory, network speed), **Rounded Corners** (6 px screen corners) |
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
     twice, and email, with validation.
  4. **Appearance**: light or dark, and one of GNOME's nine accent colors.
     The live session previews the choice.
  5. **Summary**, then **"Start using Ubuntu"**.
  
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
  - writes `~/.gitconfig` with `user.name` / `user.email`
  - retires the live user: no autologin, hidden from GDM, password locked,
    passwordless sudo removed
  
  The session then logs out to GDM, where only the new user is listed.
- **Chromium** follows the desktop, like a GNOME app:
  - **language**: its UI follows `LANG`, like the rest of the session.
    `chromium-l10n` provides the translations; the build keeps only the
    image's languages.
  - **light/dark style**: Chromium's initial preferences
    (`/etc/chromium/master_preferences`, copied into each new profile)
    set its mode to "Device". It reads the style from the settings portal,
    so it matches the choice made in the welcome app and follows later
    changes right away. The accent color isn't carried over: on Linux,
    Chromium's palette comes only from its own "Customize Chromium"
    panel.
  - **uBlock Origin Lite** is installed as an
    [external extension](overlay/usr/lib/chromium/extensions/ddkjiahejlhfcafbddmgiahcphecmpfh.json):
    Chromium downloads it from the Chrome Web Store on its first start
    (the network is needed then) and keeps it updated. It's an ordinary
    extension, so you can disable or remove it, and Chromium doesn't
    show "managed by your organization". It's the Lite version because
    Chromium 154 no longer runs Manifest V2 extensions like the original
    uBlock Origin.
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
    of the package's own patches. Right now there's one:
    [gdm3](patches/gnome/gdm3/fix-fallback-session-double-free.patch).
    Ubuntu's `prefer_ubuntu_session_fallback.patch` frees the fallback
    session name twice when there is no `ubuntu` session, so without the fix
    gdm aborts as soon as someone starts to log in on an image that only has
    the vanilla GNOME session.
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
  - the dash favorites (Nautilus, Chromium, Ghostty, Software)
  - the extensions' settings
  - no welcome tour

  AccountsService preselects the `gnome` session.
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

- It builds the ISO with `./build.sh --xkb us` on a native arm64 runner
  (`ubuntu-24.04-arm`), with rootful podman, since the ISO step needs loop
  devices.
- The GNOME 51 backport (`/cache/gnome-repo`) is kept in the Actions cache.
  Only the first build takes hours: later ones rebuild just the packages
  that changed (a new 26.10 version, different local patches, one added to
  `build-gnome.sh`). To rebuild everything, e.g. after changing the
  `Containerfile` or the build flags, delete the `gnome-repo-*` caches
  (Actions → Caches).
- It builds `qemu-macos-arm64.tar.gz` with `./qemu/build.sh` on a
  `macos-15` runner, caching the downloads.
- It publishes a release with `ubuntu-live-arm64.iso`,
  `qemu-macos-arm64.tar.gz` and `SHA256SUMS`.
  A release asset can be at most 2 GiB, and the build fails if the ISO is
  bigger. [install.sh](install.sh) downloads from there.

## Limitations

- The backported GNOME 51 packages (and glib, gtk4, pango…) get no
  updates from 26.04. Rebuilding picks up whatever 26.10 has at that point.
- With `--no-persist`, everything lives in RAM. The ISO has no installer.
- The welcome app is a first draft:
  - its UI only speaks English and Italian
  - it offers six languages and ten keyboard layouts
  - it has no timezone page
  - the live user stays on the system, locked and hidden
- The host's language reaches the guest only under QEMU (`run-qemu.sh`);
  on other hypervisors or hardware the live session starts in English.
- No sound drivers, and no firmware for real hardware (Wi-Fi, non-virtio
  GPUs): the image is aimed at VMs.
- apfs-fuse only reads APFS: Mac disks can't be written to.
- The Microsoft core fonts (Arial, Times New Roman…) aren't included: their
  license allows redistributing only the original installers. Liberation,
  Carlito and Caladea take their place with the same metrics; `sudo apt
  install ttf-mscorefonts-installer` (multiverse) fetches the real ones.
- The `ubuntu` / `ubuntu` credentials and passwordless sudo are meant for a
  live system. The welcome app locks them once your user exists. Change
  them in `build-rootfs.sh` (`LIVE_USER`, `LIVE_PASSWORD`) before
  distributing the ISO.
