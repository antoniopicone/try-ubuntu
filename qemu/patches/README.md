# QEMU patches

Applied in this order by [../build.sh](../build.sh) to QEMU 11.1.1
(`c3d48b7d1e`). All are taken unchanged from
[Try Omarchy](https://github.com/omacom/try-omarchy) (`macos/patches/`, at
`e1a0dbe98`), which carries some of them from
[startergo/homebrew-qemu-virgl-kosmickrisp](https://github.com/startergo/homebrew-qemu-virgl-kosmickrisp).
Like QEMU, they're GPL-2.0.

| Patch | What it does |
|---|---|
| `qemu-texture-borrowing-11.1.patch` | OpenGL in the Cocoa display (`-display cocoa,gl=es`): virtio-gpu-gl scanouts are borrowed from virglrenderer as textures and drawn in the window through ANGLE (EGL / OpenGL ES on Metal) |
| `qemu-gpu-spike-resolution-fix.patch` | Cocoa redraws the scanout only when it changed (without it, it redraws every refresh tick) |
| `qemu-cocoa-dynamic-display.patch` | the window's size (in backing pixels, so HiDPI) and the display's refresh rate reach the guest through virtio-gpu's EDID: the guest resolution follows the window |
| `qemu-darwin-strchrnul-compat.patch` | builds with a macOS 26 SDK still run on macOS 15.0 (`strchrnul` is 15.4+) |
| `qemu-hvf-free-page-reclaim.patch` | with `virtio-balloon-pci,free-page-reporting=on`, the pages the guest frees go back to macOS (HVF needs the mapping replaced) |
| `qemu-hvf-mapped-sections.patch` | HVF only unmaps sections it mapped: fixes a crash (`EXC_GUARD` in `hv_vm_unmap`) when the guest writes to the UEFI flash (pflash) |
| `qemu-darwin-gpu-fence-poll.patch` | polls virglrenderer's fences every 1 ms instead of 10 on macOS: 10 ms is longer than a frame at 120 Hz and stalls the guest's uploads |

Nested virtualization needs no patch: QEMU 11.1 has HVF's EL2 and GICv3
support (`-machine virt,gic-version=3,virtualization=on -accel
hvf,kernel-irqchip=on`, macOS 26 and an M3 or newer).

virglrenderer gets the patches of
[startergo/homebrew-virglrenderer](https://github.com/startergo/homebrew-virglrenderer)
v1.0.42 (downloaded, listed in `virgl_patches` in build.sh).
