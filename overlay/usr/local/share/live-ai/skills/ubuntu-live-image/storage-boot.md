# Live or installed, btrfs, snapshots, boot

## Which one is this?

```bash
[ -f /etc/try-ubuntu/installed ] && echo installed || echo live
findmnt -no SOURCE,FSTYPE /
cat /run/btrfslive/booted-snapshot 2>/dev/null   # set when booted from a snapshot
systemd-detect-virt                              # "qemu"/"kvm" in a VM, "none" on hardware
```

## The live system

The ISO's `live/rootfs.btrfs` is a compressed btrfs **seed** (read-only). At boot the
initramfs script `btrfslive` adds a writable **sprout**:

- **RAM** (the default without a persistent disk): a file on tmpfs. **Lost at shutdown.**
- **A persistent disk**: under QEMU the disk with serial `ubuntu-persist`
  (`run-qemu.sh`, on by default), or `btrfslive.persist=DEV`. It extends the seed of *that*
  ISO build only: after a new ISO, `run-qemu.sh` moves the old disk aside.

On top, the usual subvolumes: `@` → `/`, `@home` → `/home`, `@var` → `/var`,
`@snapshots` → `/.snapshots`. It's real btrfs, so snapshots and the rest work, but don't
`btrfs device add/remove` on it: that's how installing works (below), and doing it by hand
can strand the system.

Kernel parameters: `btrfslive.ram=<MiB>`, `btrfslive.persist=<DEV>|no`,
`btrfslive.snapshot=<N>|ask`, `btrfslive.label=<LABEL>`.

## Snapshots

- **`/`** (config `root`): #1 is the image as built; one before every apt/dpkg run
  (`/etc/apt/apt.conf.d/80-snapper`); any made by hand. Number cleanup keeps 10.
- **`/home`** (config `home`): every hour, 24 hourly / 7 daily / 4 weekly, in
  `/home/.snapshots`. Files shows them as **Previous Versions** (right-click a file or
  folder): the easiest way for the user to get a file back. They're not in Cloud Backup.
- The user is in both configs' `ALLOW_USERS`: `snapper` works without root.

### Getting something back

- **A file** → Previous Versions in Files, or
  `snapper -c home status <a>..<b>` and copy it out of `/home/.snapshots/<n>/snapshot/`.
- **System files** → `snapper -c root status <pre>..<post>`, `snapper -c root diff ...`,
  then `snapper -c root undochange <pre>..<post> <path>` (after the user's yes).
- **The whole system, live** → reboot, pick the snapshot in Limine's *Snapper snapshots*
  section (*Choose at boot* lists them all). That boots a **writable copy**
  (`@boot-snapshot`); `@` is left untouched and the copy is dropped at the next normal
  boot. To keep it: `live-rollback` makes it the new `@` and keeps the old one as
  `@old-<date>`. Only meaningful with a persistent disk.
- **The whole system, installed** → its Limine menu has the kernels, not the snapshots:
  `live-rollback` doesn't apply. Use `snapper undochange` on what changed, and never
  `snapper rollback` (it changes the default subvolume, which this layout, mounting `@` by
  name, ignores).

## Installed on a disk

The welcome app's install moved the running filesystem onto the disk with
`btrfs device add` / `remove`. Afterwards:

- `/etc/fstab` mounts `@`, `@home`, `@var`, `@snapshots` from the `Ubuntu-root` btrfs,
  and the EFI system partition on `/boot/efi`.
- **Limine** boots it, from the EFI system partition (Limine reads only FAT). Its kernels
  and initramfs are copies there, which `live-limine-update` keeps in step: the kernel's
  and initramfs-tools' hooks run it after every kernel or initramfs change. On arm64 it
  extracts the raw `Image` from Ubuntu's EFI zboot vmlinuz (`unzboot.py`).
- **Secure Boot must stay off**: Limine isn't signed. If the firmware boots something else,
  check that first.

After a kernel upgrade, before suggesting a reboot, check the menu has the new kernel:

```bash
ls /boot/vmlinuz-* /boot/initrd.img-*
pkexec /usr/bin/grep -n "$(ls /boot/vmlinuz-* | sort -V | tail -1 | sed 's|.*/vmlinuz-||')" /boot/efi/boot/limine/limine.conf
```

If it's missing, run `pkexec /usr/local/sbin/live-limine-update` and look at its output;
don't hand-edit Limine's menu: it's rewritten at every kernel update. The EFI system partition is root-only: every access needs
privileges, or errors read like "not found".

## The two kernels

- **The QEMU flavour** (the releases' ISOs): the "virtual" kernel, pruned to what a VM
  needs, and **no firmware**. No Wi-Fi, no GPUs but virtio-gpu, no sound but
  virtio-sound. A missing driver here is by design: installing firmware packages won't
  bring the pruned modules back.
- **The hardware ISO** (`build.sh --hardware`, what `install.sh --on-usb` writes): the
  generic kernel, all of linux-firmware, Intel's sound firmware, the Vulkan drivers.
  NVIDIA's proprietary driver isn't included.

## The VM integration (QEMU)

- **Clipboard**: spice-vdagent with the QEMU window.
- **The host's folder** (`run-qemu.sh --shared-folder`): 9p, shown through bindfs in
  `/media/<name>`, so in Files.
- **Graphics**: virtio-gpu, with virgl on the host's GPU (the QEMU from `qemu/build.sh`)
  or llvmpipe in software. Ghostty renders in software either way, and falls back to
  Ptyxis when it can't start (`/usr/local/bin/ghostty`, a dpkg diversion of the real one).
- **The language** comes from the host at boot (`live-locale`), under `run-qemu.sh` only.
