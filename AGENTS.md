# AGENTS.md

Notes for agents (and humans) working on micro-finix. README.md covers
what it is and how to use it; this file covers why, the constraints,
the gotchas, and where the work stands.

## Why this exists

Target: small devices of several kinds: boards (first: Raspberry Pi
Zero 2 W, later the ARMv6 Zero), NAND routers that run OpenWrt today
(first: the home MT7621 routers, EdgeRouter X and DAP-X1860), and
other hardware. NixOS is too heavy there, and trimming NixOS
was tried before and did not work out -- don't propose a debloated
NixOS as the answer.

Liminix (liminix.org, src gti.telent.net/dan/liminix) was evaluated
first: good build pipeline, but its own non-NixOS module set, router
focus, no Pi device, no Wi-Fi client (hostapd only, no wpa_supplicant),
not a flake. Finix (github.com/finix-community/finix) has NixOS-shaped
modules on finit, incl. iwd, but targets glibc desktops and has no
image/kernel pipeline. micro-finix = finix as the system layer +
Liminix's approach to building (musl cross pkgs, Kconfig-attrset
kernel, image outputs). Both upstreams are MIT.

## Design constraints (decided)

- **Hardware-agnostic core.** Arch/libc, kernel, boot, storage and
  update are pluggable backends selected by options (finix's
  `providers.*` contract pattern). Nothing outside a backend mentions a
  specific board or firmware (e.g. `config.txt` stays in the Pi boot
  backend). The Pi is just the first device. Concretely:
  - device = `platform` (nixpkgs crossSystem incl. gcc arch/float) +
    kernel symbols + backend choices (`devices/<name>`);
  - boot backend (`modules/boot/<backend>.nix`) picks the kernel
    artifact (`micro.boot.kernelFile`), whether it needs a FAT boot
    partition (`micro.boot.partition.enable`) and what goes on it;
  - storage layout (`modules/storage/<layout>.nix`) numbers the
    partitions (declared by name + `order`), names their devices,
    picks the data filesystem, builds the flashable image and lists
    the update modes it carries. Only `block` (MBR) exists; raw NAND
    routers need a `ubi` layout (image mode only).
- **Router class: NAND (>= 128 MiB) with A/B image mode on UBI.**
  16-32 MiB NOR routers are out of scope (the compressed store alone
  is ~23 MiB).
- **Small base, expanded per device class.** The base (finit,
  busybox, update modes, storage/boot backends) stays minimal and
  headless; heavier capabilities (Wi-Fi client/AP, graphics, input,
  power management for tablets/phones such as the tf700) come as
  opt-in profiles and finix module imports on top, never as defaults.
  Candidate devices beyond Pi/routers: tf700 (Tegra 3, armv7; mainline
  U-Boot from microSD, so `block` layout + a generic U-Boot extlinux
  backend). Open risk for graphical devices: nixpkgs' musl cross
  builds of the display stack are untested.
- **Both update modes stay supported**: `image` (tmpfs root, A/B
  read-only squashfs store, `micro.slot=a|b`) and `closure` (writable
  ext4 root, switch). Don't drop one to simplify.
- **No data loss**: service state lives on the data partition, which
  updates never rewrite.
- **Trims are evidence-based**: cut what the dependency graph shows
  (`nix-store -qR` on the drv + `--referrers`), and keep everything
  overridable (mkDefault / `micro.excludePackages`).

## Gotchas

- Cross builds skip `checkPhase`; the Kconfig dropped-symbol check
  runs in `postBuild` for that reason. A dropped symbol usually means a
  missing parent menu (`BLK_DEV`, `NET_CORE`, `MISC_FILESYSTEMS`).
- Finix service modules are opt-in imports via the `modules`
  specialArg (`modules.getty`, `modules.dropbear`, ...). Setting
  `services.<x>` without importing fails with "option does not exist".
- Finix's stock kernel module lists name PC modules; with the micro
  kernel they are mkForce'd empty (everything built in).
- Finix writes `/etc/pam.d/*` even with `security.pam.enable = false`;
  the profile forces `security.pam.services = { }` when PAM is off.
- util-linux without PAM needs `withLastlog = false` (assertion).
- userborn (finix's user creation, hard-wired in its users module) is
  Rust with bindgen: drags clang, compiler-rt and a target python into
  the build. Biggest remaining trim; would need a static passwd
  generator for image mode.
- nixpkgs' kernel postInstall runs `xargs rm` on `modules.order`;
  with `MODULES=y` and nothing `=m` that list is empty and the build
  dies with "rm: missing operand" (exit 123). `modules/kernel` patches
  in `xargs -r` and throws at eval if the upstream line changes.
- MIPS' `make install` ignores nixpkgs' installkernel hook and installs
  `vmlinux-<release>` plus, with SYS_SUPPORTS_ZBOOT (Malta, Ralink),
  `vmlinuz-<release>`, which isn't built ("cannot stat 'vmlinuz'").
  `modules/kernel` drops the `install` target on MIPS and copies the
  image and System.map to `$out` itself.
- 32-bit musl calls the legacy time32 syscalls (ppoll, nanosleep, ...)
  whenever the value fits in 32 bits; `allnoconfig` drops them
  (`COMPAT_32BIT_TIME`), so they return ENOSYS: `sleep` returns at
  once, mdevd dies ("unable to iopause") and stage 1 hangs at
  coldplug. The kernel base turns it on for 32-bit platforms. Debug
  trick: boot the initrd's busybox with `rdinit=<busybox>/bin/sh`.
- finit's shutdown closes all fds and relies on vfork() suspending
  PID 1 while the child calls reboot(). musl's vfork() is plain fork()
  on MIPS (only x86, arm, aarch64, riscv64, s390x, sh have a vfork.s),
  so PID 1 resumed, its event loop failed and init exited: "Attempted
  to kill init" on every poweroff/reboot. `patches/finit-vfork-as-fork.patch`
  (via `finit.package` in the profile) makes the parent wait; worth
  sending upstream.
- finit's watchdogd renames itself `@finit-watchdog` so the shutdown
  kill loop spares it; finit's switch_root uses the same loop, so the
  initrd's watchdogd survived into stage 2 unsupervised, holding
  /dev/watchdog, and stage 2's own crashed in a loop ("Resource busy").
  Only shows on hardware with a watchdog (QEMU has none).
  `patches/finit-switch-root-watchdog.patch` hands it over (SIGTERM =
  magic close) before switching; upstream candidate too.
- `allnoconfig` drops symbols whose Kconfig default is on for the SoC
  (e.g. `CLK_BCM2835`, `default ARCH_BCM2835`); the strict check
  doesn't see these because nobody asked for them. Symptom: drivers
  stuck in "deferred probe pending: could not get clk". List SoC
  infrastructure (clocks, pinctrl, power domains) explicitly.
- `/etc/shells` only lists shells of enabled `programs.<shell>` modules
  (finix), and the profile installs users' shells without them, so it
  held just /bin/sh. dropbear refuses every login (key or password) for
  a user whose shell isn't listed: "Permission denied
  (publickey,password)". The profile adds every user's shell.
- Built-in drivers (brcmfmac, cfg80211's regulatory.db) request
  firmware while probing, before the real root is mounted. finix's
  initrd /lib is a symlink into the modules store path, so early
  firmware goes to the initrd's /firmware with
  `firmware_class.path=/firmware`; activation resets the path to
  hardware.firmware.
- Finit itself pulls procps (sysctl).
- finix sets root's shell to `pkgs.bashInteractive` and writes
  `/run/current-system/sw/bin/bash` into passwd without installing it,
  so login failed ("Cannot execute .../bin/bash"). The profile puts
  every user's shell package on the system path; root keeps bash
  (already in the closure for `switch-to-configuration`).
- `overlays/micro.nix` applies to `buildPackages` too. Trims of
  packages the native stdenv bootstrap uses (xz, findutils, ...) are
  gated on `cross` there, or they rebuild the native toolchain (a
  dry-run showed 746 derivations incl. GHC, LLVM, Rust).
- Closure trims (119.0 -> 83.4 MiB), all in `overlays/micro.nix` and
  target-only: e2fsprogs without libarchive (dropped openssl, libxml2;
  libarchive only serves `mke2fs -d`), `util-linuxMinimal` = the
  system util-linux (was a second copy via e2fsprogs' libuuid and
  finix's `logger`), `--disable-nls` for e2fsprogs/findutils/xz, and
  `unixtools.*` wrappers without man pages (they pulled whole procps
  and util-linux `-man` outputs).
- finix sets PATH only through pam_env. With PAM off, busybox login
  hardcodes `/sbin:/bin:/usr/sbin:/usr/bin`, so a login shell found no
  commands. The profile sets `environment.variables.PATH` (written to
  `/etc/profile.d/session-vars.sh`) when PAM is off.
- The qemu-direct runner uses a headless single-target QEMU override;
  stock `buildPackages.qemu` dragged in ~2600 derivations (gtk, SDL,
  gstreamer, and gobject-introspection cross-built for the guest).
  Upstream's postInstall links `qemu-kvm` to the build machine's
  `qemu-system-*`, which a single foreign target doesn't build, so the
  override empties it (throws if upstream changes it).
- finix's security wrappers take `unsecvars.h` from `srcOnly
  pkgs.glibc`, which on musl cross-builds glibc and fails. The profile
  turns every wrapper off (finix's own mount/umount included) and
  asserts none is enabled on musl.
- nixpkgs' skaware builder (execline, mdevd, s6...) calls a bare
  `pkg-config`, which doesn't exist in a cross stdenv (only the
  target-prefixed wrapper does). `overlays/micro.nix` puts a shim on
  PATH for all skaware packages.
- `finix.cachix.org` holds only finix's native glibc builds -- none of
  the musl cross paths. `cache.darker.ro` is private (not publicly reachable).
- Attic only gets runtime closures from CI, not the cross toolchains.
  For iteration without CI or local heavy builds, evaluate on the workstation and
  build on the builder: `nix build --eval-store auto --store
  ssh-ng://<builder> <attr>` (as a trusted user there), then
  `nix copy --no-check-sigs --from ssh-ng://<builder> <out>`.
- Eval-checked (not built) for `pkgsCross.muslpi` (ARMv6 Zero) too:
  finit, busybox, iwd, dropbear, dhcpcd, chrony, nftables, mdevd.
- The cross rustc (needed by userborn) fails for ARMv6 musl:
  compiler_builtins' naked `bx lr` goes into module-level asm, which
  LLVM < 23 parses for the bare `arm-` triple (ARMv4, no `bx`); rustc
  passes target features to module asm only with LLVM >= 23
  (rust-lang/rust#160594) and nixpkgs builds it against LLVM 21. With
  fastCross the target std is compiled by the native rustc, so patching
  rustc's target spec does nothing; `devices/rpi-zerow/rustc-armv6.nix`
  rewrites `bx lr` in the library source as `.inst 0xe12fff1e`.
- 32-bit ARM installs DTBs flat in `dtbs/` (arm64: `dtbs/broadcom/`).

## CI

`.forgejo/workflows/build.yml` on forge.darker.ro, `runs-on: nixos-big`
(the builder). Builds each device's example runner + disk image, prints the
toplevel closure size, pushes to the `darker` attic cache on `main`.
Requires Actions enabled on the repo and `ATTIC_TOKEN` available to it.
Read job outcomes from the job log, not from indirect signals.

## Status (2026-10-27)

- Evaluates in both update modes; the qemu-aarch64 kernel `.config`
  builds clean (581 `=y`, no `=m`).
- Trims: 114 -> 94 target packages in the qemu-aarch64 image closure.
- First green CI build (runner + disk image) after fixing the kernel
  (empty `modules.order`), the musl glibc wrappers and the runner's
  QEMU (see Gotchas). Toplevel closure: 119.0 MiB, trimmed to 83.4 MiB
  (110 paths); about 15 MiB of RAM in use after login.
- Image mode boots in QEMU on both slots to a bash login:
  tmpfs `/`, squashfs store from the slot's partition, data partition
  on `/var/lib`. The factory image carries the store in both slots; a
  slot without a squashfs falls back to the other one, and
  `/dev/micro/slot` records the slot actually booted. `/var/lib`
  survives a slot switch and `poweroff` unmounts cleanly.
- Closure mode boots in QEMU: writable ext4 `/` on the root
  partition, `/nix/store` a read-only bind of it, and both `/` and
  `/var/lib` survive a reboot. The root filesystem is grown to its
  partition at image build time
  (`micro.storage.partitions.<name>.growFilesystem`, on by default for
  the closure root). Built as `examples.closure-mode` (qemu-aarch64).
- The guest clock starts at 2000 (`RTC_HCTOSYS` is off); fine for
  testing.
- finit's pidfile plugin depends on its netlink plugin, but finix's
  initrd ships only pidfile.so and bootmisc.so, so stage 1 logged
  "Failed loading plugin .../netlink.so". The profile adds netlink.so
  to `boot.initrd.contents` (70 KB).
- Backends split out (boot partition opt-in, partitions by `order`,
  `block` layout in its own file); the QEMU disks lost their unused FAT
  partition (image: vda1/vda2 slots, vda3 data; closure: vda1 root,
  vda2 data). Both modes re-tested in QEMU after the split.
- `qemu-mipsel` (Malta, 24Kc, MIPS32r2 soft-float, 256 MiB) added as
  the MT7621 stand-in; boots image mode in QEMU to a bash login in
  ~20 s (11 MiB RAM used), after fixing the MIPS kernel install and
  32-bit time syscalls (see Gotchas). rustc/userborn built fine for
  mipsel. `poweroff`/`reboot` unmounted cleanly but then panicked
  ("Attempted to kill init"): finit relies on vfork, which musl/MIPS
  implements as fork (see Gotchas). Patched, plus Malta PIIX4
  power-off and syscon reboot: reboot and poweroff now clean, /var/lib
  survives a reboot, QEMU exits on power-off.
- `ram` storage layout: the squashfs store rides in a second cpio
  archive appended to the initrd (`micro.boot.ramdisk`), mounted via
  loop; `/var/lib` is tmpfs. Booted in QEMU (aarch64, no disk).
- `dap-x1860` device + `uboot-fit` boot backend (kernel, DTB with
  per-slot bootargs, ramdisk in one FIT; OpenWrt's relocate stub; load
  address 0x82000000). Kernel adds OpenWrt's MT7621 NAND driver (patch
  410 + driver file + `mtk_bmt.h` stubs, NMBM off) from the pinned
  `openwrt` flake input (`microSources.openwrt` in modules). Builds
  `fit` (finix from RAM) and `fitShell` (`rdinit=` busybox), ~37 MiB
  each, uncompressed kernel. Not run on the hardware yet.
- `rpi-zero2w` device + `rpi-firmware` boot backend: mainline kernel
  and DTB, Pi firmware (unfree, allowed via the device's
  `nixpkgsConfig`) on the FAT partition with config.txt and per-slot
  cmdline-<slot>.txt (`cmdline=` picks the slot). SD on sdhost only so
  it is mmcblk0. Boots on the hardware to a root login: store from
  mmcblk0p2 (slot a), data mmcblk0p4, 20 MiB of 428 MiB used.
  simpledrm picks up the firmware framebuffer (HDMI untested: broken
  adapter). Debug access without HDMI or UART: the data port runs USB
  gadget serial (g_serial, console + getty on ttyGS0 = /dev/ttyACM0 on
  the PC; `picocom --imap lfcrlf`), and the ACT LED shows the kernel
  heartbeat. A USB keyboard needs host/dual-role mode instead.
- Opt-in profiles `micro.wifi.client` (iwd with its own DHCP, dbus,
  syslogd, cfg80211 + iwd's crypto) and `micro.ssh` (dropbear, root's
  authorized keys written at boot). The Zero's radio is a 43436s that
  reports as BCM43430/1; firmware for all Zero 2 W radio variants is
  packaged (and in the initrd). Runs on hardware: on Wi-Fi via iwctl-provisioned credentials, SSH with the user's keys.
- Opt-in `micro.dns` (`dhcp`: finix's resolvconf, fed by iwd;
  `nameservers`/`search`: static /etc/resolv.conf, or prepended to the
  DHCP ones) and `micro.ntp` (busybox ntpd client, already in the
  closure; pool.ntp.org by default, warns when the servers are names
  and no DNS is set). Without `micro.dns` there is no /etc/resolv.conf.
  On a Zero 2 W the DHCP variant adds only openresolv (~0.1 MiB).
  Built, not yet booted; busybox ntpd queried the pool from ct1011 with
  `-w` (no clock change).
- `micro.secrets` (modules/secrets.nix): files on the data partition
  from a command run on the deploying machine (sops, pass, cat, ...),
  never in the store. `provisionImage` writes them into a copy of the
  disk image (debugfs on the ext4 data partition), `pushSecrets` over
  SSH (busybox `tar -x -o`, then chown/chmod per file; existing parent
  dirs untouched, new ones 0755), `deploy` pushes before updating.
  Tested: provision-image + QEMU boot (modes, owners, a path with a
  space, a service reading its file), push-secrets against busybox tar.
- `rpi-zerow` (ARMv6 Zero W, BCM2835): armv6 musl hard-float
  (`muslpi` platform), zImage, `bcm2835-rpi-zero-w.dtb`; 32-bit ARM
  kernel needs MMU, ARCH_MULTI_V6, AEABI, VFP, KUSER_HELPERS listed
  (allnoconfig drops them). Disk image builds; not booted on hardware
  yet.

## Next

1. `qemu-mipsel`: test closure mode and slot b (image mode, slot a,
   reboot and poweroff verified).
2. `rpi-zero2w`: A/B slot switching (config.txt `cmdline=`, or
   `tryboot`/`autoboot.txt` if the Zero 2 W firmware supports it),
   HDMI check, USB dual-role for a keyboard.
3. DNS and NTP: options exist (`micro.dns`, `micro.ntp`, both off by
   default); turn them on for the Wi-Fi hosts and check on hardware
   that ntpd steps the 2000 clock and iwd's DHCP DNS reaches
   /etc/resolv.conf. Then maybe keep the last synced time on /var/lib
   so the clock doesn't restart at 2000 before the network is up.
4. Deployment (decided: push from the workstation, `nix run .#deploy-<device>`,
   like the servers). Image mode: CI builds the slot artifact (store
   squashfs + that slot's boot files) into attic; the deploy app
   streams it over SSH into the inactive slot, an on-device
   `micro-update` verifies it and arms a one-shot trial boot; a health
   check confirms the slot, otherwise the next boot falls back. Needs
   per-slot boot files on the Pi FAT (kernel/initrd shared today) and
   a rollback mechanism (Pi `tryboot` if the Zero 2 W firmware has it,
   else a boot counter the initrd checks). Closure mode: nix copy +
   switch-to-configuration.
5. First router: the spare DAP-X1860 A1 (same model as the home APs,
   5 GHz faulty, free to flash; the live APs stay untouched). Read
   from ap1001: MT7621 (1004Kc, 4 threads), 249 MB RAM, NAND with 128
   KiB erase blocks; mtd3 "kernel" 8 MiB raw (bootloader loads it),
   mtd8 "ubi" 100 MiB (800 PEBs, ~97 MiB usable). Needs a MT7621
   device, a `ubi` storage layout (A/B squashfs volumes + UBIFS data)
   and a U-Boot boot backend (uImage/FIT via `micro.boot.kernelFile`).
   Constraints: only one kernel partition, so kernel+initrd aren't A/B
   (fixed kernel that selects the slot, or a loader from UBI; check
   whether its U-Boot reads UBI); kernel+initrd must fit 8 MiB (initrd
   is 5.6 MiB today); AP Wi-Fi (MT7915) needs mt76 + firmware +
   hostapd, not iwd. Recovery (OpenWrt wiki, toh/d-link/dap-x1860):
   bootloader web recovery (hold reset while powering on until the
   orange LED blinks, http://192.168.0.50 from 192.168.0.x, Chromium
   only, flashes any unencrypted image; back to stock with the
   decrypted `kernel_DAP-X1860.bin`) and serial (115200 8N1 3.3 V;
   1 Tx, 2 GND, 3 Rx, 4 Vcc; U-Boot menu has "Load image and run" and
   a console, so test kernels can run from RAM without flashing).
   From the OEM bootlog: U-Boot ELX-v1.0.4 boots a legacy uImage,
   LZMA, from NAND 0x180000 (mtd3) to RAM 0x80010000, kernel load
   address 0x81001000; console=ttyS0,115200. The NAND uses MediaTek
   NMBM (bad-block remapping); OpenWrt carries kernel patches for it.
   Check whether mainline handles NMBM and the MT7621 NAND controller,
   or which OpenWrt ramips patches the device kernel needs.
6. Optional `micro.kernel.tiny` preset (EXPERT on, optimise for size,
   per-device `NR_CPUS`, no VT/KALLSYMS/INPUT, PCI only where needed).
   The kernel is already `allnoconfig` plus listed symbols (581 `=y`,
   no `=m`; no AX25/WLAN/USB/sound/DRM unless a device asks), so this
   trims generic options, not drivers: the 8.0 MiB `Image` carries
   `NR_CPUS=512`, `KALLSYMS`, `VT`, `INPUT`, and arm64's allnoconfig
   platform defaults. Keep it a preset devices opt into, each symbol
   still overridable (`mkDefault`, `"n"`).
7. Replace userborn in image mode.
8. Closure-mode update tooling (copy closure + switch, GC).
