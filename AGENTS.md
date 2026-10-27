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
- Finit itself pulls procps (sysctl).
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
- First full cross build handed to CI; outcome not yet confirmed.
  **Nothing has booted yet.**

## Next

1. Boot in QEMU: `run-micro-vm a`, then slot b; verify the A/B slot
   task and data partition mount.
2. `rpi-zero2w` device + Pi firmware boot backend (FAT: firmware,
   `config.txt`, kernel, dtb, per-slot cmdline; check whether the Zero
   firmware supports `tryboot`/`autoboot.txt` for A/B, else a small
   selector).
3. Wi-Fi client via finix's iwd + brcmfmac firmware.
4. Optional `micro.kernel.tiny` preset (EXPERT on, optimise for size,
   per-device `NR_CPUS`, no VT/KALLSYMS).
5. Replace userborn in image mode.
6. Closure-mode update tooling (copy closure + switch, GC).
