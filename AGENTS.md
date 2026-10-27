# AGENTS.md

Notes for agents (and humans) working on micro-finix. README.md covers
what it is and how to use it; this file covers why, the constraints,
the gotchas, and where the work stands.

## Why this exists

Target: small boards (first: Raspberry Pi Zero 2 W, later the ARMv6
Zero, and other hardware). NixOS is too heavy there, and trimming NixOS
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
  backend). The Pi is just the first device.
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
- Finit itself pulls procps (sysctl).
- finix hard-sets root's shell to `pkgs.bashInteractive` and writes
  `/run/current-system/sw/bin/bash` into passwd without installing it,
  so login failed ("Cannot execute .../bin/bash"). The profile defaults
  root and normal users to busybox ash and puts every user's shell
  package on the system path. bash-interactive stays in the closure
  only for finix's `switch-to-configuration` shebang.
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
- Eval-checked (not built) for `pkgsCross.muslpi` (ARMv6 Zero) too:
  finit, busybox, iwd, dropbear, dhcpcd, chrony, nftables, mdevd.

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
  QEMU (see Gotchas). Toplevel closure: 119.0 MiB.
- Boots in QEMU (image mode) on both slots to a busybox ash login:
  tmpfs `/`, squashfs store from the slot's partition, data partition
  on `/var/lib`. The factory image carries the store in both slots; a
  slot without a squashfs falls back to the other one, and
  `/dev/micro/slot` records the slot actually booted.
- finit's pidfile plugin depends on its netlink plugin, but finix's
  initrd ships only pidfile.so and bootmisc.so, so stage 1 logged
  "Failed loading plugin .../netlink.so". The profile adds netlink.so
  to `boot.initrd.contents` (70 KB).

## Next

1. Closure mode in QEMU. Image mode is verified: both slots boot,
   slot fallback works, `/var/lib` survives a slot switch, and
   `poweroff` unmounts cleanly. The guest clock starts at 2000
   (`RTC_HCTOSYS` is off).
2. `rpi-zero2w` device + Pi firmware boot backend (FAT: firmware,
   `config.txt`, kernel, dtb, per-slot cmdline; check whether the Zero
   firmware supports `tryboot`/`autoboot.txt` for A/B, else a small
   selector).
3. Wi-Fi client via finix's iwd + brcmfmac firmware.
4. Optional `micro.kernel.tiny` preset (EXPERT on, optimise for size,
   per-device `NR_CPUS`, no VT/KALLSYMS).
5. Replace userborn in image mode.
6. Closure-mode update tooling (copy closure + switch, GC).
