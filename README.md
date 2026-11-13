# micro-finix

> [!WARNING]
> **This code is written with the help of LLMs, under strict human
> supervision.** Changes are reviewed and tested by a human before they
> are committed, and two Raspberry Pi Zero boards run it around the
> clock. Still, read what you deploy, especially anything that touches
> your boot medium or your secrets. Issues and corrections are welcome.

An unofficial project built on
[finix](https://github.com/finix-community/finix) (finit as pid 1,
NixOS-shaped modules), not part of it. It builds finix the way
[Liminix](https://www.liminix.org/) builds router firmware:
cross-compiled musl userland, a minimal kernel from an attrset of
Kconfig symbols, and flashable disk images.

Licensed under the MIT license (see `LICENSE`).

## Purpose

A very small Linux system, built on musl libc, for very small devices:
single-purpose boards, routers and access points, sensors and relays.
Each system does one job, runs from a read-only image (by default) and
is updated as a whole.

* **Small by default.** musl, busybox, finit as pid 1, a kernel with
  only the Kconfig symbols the board needs. No PAM, no systemd, no
  locales, no man pages, no Nix daemon on the device. A Wi-Fi relay
  node with SSH and an MQTT client is 79 MiB of store on a Pi Zero W
  (110 MiB on the 64-bit Zero 2 W) and uses 18-26 MiB of RAM.
* **NixOS-shaped.** finix's modules look like NixOS's (`services.*`,
  `users.*`, `environment.etc`, `finit.services`), so a configuration
  reads like one, and everything is built from a flake.
* **Robust updates.** Image mode: A/B slots with a squashfs store, a
  tmpfs root and a separate data partition that updates never touch;
  `nix run .#deploy` streams an update over SSH. Closure mode (a
  writable ext4 root, NixOS-style) for boards with storage to spare.
* **Cross-built.** Everything is built on an x86_64 machine; nothing
  compiles on the device.
* **musl, not glibc.** Every system uses [musl](https://musl.libc.org/)
  as its C library, on every architecture: all packages are built from
  nixpkgs for a `*-linux-musl` target. Most of nixpkgs builds fine for
  musl, but not all of it, and binaries built against glibc (prebuilt
  vendor tools, anything downloaded rather than built) won't run.
  Statically linked or pure Go/Rust programs are the easy case.

What it is **not**: there is no desktop here. No graphics stack, no
Wayland or X11, no audio, no session management, no package manager on
the device. It isn't a trimmed-down NixOS either; for a machine with a
screen and a user, use NixOS (or finix itself).

## Supported devices

| device        | hardware                                          | target (musl)                        | boot            | status                          |
|---------------|---------------------------------------------------|--------------------------------------|-----------------|---------------------------------|
| `rpi-zero2w`  | Raspberry Pi Zero 2 W (BCM2710A1, 4x Cortex-A53, 512 MiB) | `aarch64-unknown-linux-musl`         | Pi firmware     | runs on hardware: Wi-Fi, SSH, A/B updates |
| `rpi-zerow`   | Raspberry Pi Zero W (BCM2835, ARM1176, 512 MiB)   | `armv6l-unknown-linux-musleabihf` (ARMv6KZ, VFPv2 hard-float) | Pi firmware     | runs on hardware: Wi-Fi, SSH, A/B updates |
| `dap-x1860`   | D-Link DAP-X1860 A1 (MediaTek MT7621A, 256 MiB, NAND) | `mipsel-unknown-linux-musl` (MIPS32r2, soft-float) | U-Boot FIT, from RAM | builds; not run on hardware yet |
| `qemu-aarch64`| QEMU `virt`                                       | `aarch64-unknown-linux-musl`         | QEMU direct     | boots in QEMU, both update modes |
| `qemu-mipsel` | QEMU `malta` (24Kc), stand-in for MT7621 routers  | `mipsel-unknown-linux-musl` (MIPS32r2, soft-float) | QEMU direct     | boots in QEMU                   |

Three CPU targets so far: 64-bit ARM, 32-bit ARMv6 and 32-bit
little-endian MIPS, all with musl as the C library (a glibc platform
isn't built or tested). Any nixpkgs musl `crossSystem` can be a platform; a new
board needs a device (kernel symbols, boot backend, storage) more than
a new architecture. Devices of the same target share one cross
toolchain.

## Design

The core is hardware-agnostic. Everything that depends on the board is
a backend selected by options:

| concern       | option                     | backends today                                 |
|---------------|----------------------------|------------------------------------------------|
| CPU / libc    | device `platform`          | any nixpkgs `crossSystem`                      |
| kernel        | `micro.kernel.*`           | allnoconfig + attrset                          |
| boot          | `micro.boot.backend`       | `qemu-direct`, `rpi-firmware`, `uboot-fit`     |
| storage       | `micro.storage.layout`     | `block` (MBR), `ram` (store in the initrd)     |
| updates       | `micro.update.mode`        | `image`, `closure`                             |

## Layout

```
flake.nix               lib.microSystem, devices, example builds
lib/micro-system.nix    evaluates finix + micro modules on a cross pkgs set
modules/kernel/         Kconfig attrset -> allnoconfig .config -> kernel
modules/update.nix      image (A/B squashfs) vs closure (ext4) mode
modules/storage/        storage layouts: partitions by name/order; block.nix = MBR disk image
modules/boot/           boot backends (kernel artifact, optional boot partition, runners)
devices/<name>/         platform (crossSystem) + hardware module
                        (see Supported devices)
examples/               example system configurations (see Examples)
templates/default/      `nix flake init` template for your own board
```

## Devices

A device is a plain attrset, because the platform has to be known
before module evaluation (it picks the package set):

```nix
{
  platform.config = "aarch64-unknown-linux-musl";
  module = { ... }: {
    micro.kernel.enable = true;
    micro.kernel.config = { SERIAL_AMBA_PL011 = "y"; /* ... */ };
    micro.storage.device = "/dev/vda";
    micro.boot.backend = "qemu-direct";
    micro.console = "ttyAMA0";
  };
}
```

## Update modes

Both modes boot the same finix toplevel and run finix activation on
every boot. Service state lives on a data partition that updates never
touch.

* **image**: tmpfs `/`, read-only squashfs `/nix/store` in slot A or B,
  picked by `micro.slot=a|b` on the kernel command line.
  Disk: `boot | root-a | root-b | data`.
* **closure**: writable ext4 root holding `/nix/store`.
  Disk: `boot | root | data`.

## Usage

```sh
# build and boot the example in QEMU (slot a)
nix build .#legacyPackages.x86_64-linux.qemu-aarch64.config.system.build.runner
./result/bin/run-micro-vm a        # login: root / micro

# raw disk image
nix build .#legacyPackages.x86_64-linux.qemu-aarch64.config.system.build.diskImage
```

## Examples

`examples/minimal.nix` (console login, root / micro) is built for every
device as `legacyPackages.x86_64-linux.<device>`. The others build on
it and target one device each, as
`legacyPackages.x86_64-linux.examples.<name>`:

| example        | device       | shows                                                     |
|----------------|--------------|-----------------------------------------------------------|
| `wifi-node`    | rpi-zero2w   | Wi-Fi (iwd), DNS from DHCP, NTP, SSH keys; where Wi-Fi credentials go |
| `service`      | qemu-aarch64 | your own finit service: busybox httpd + CGI, state on `/var/lib` |
| `closure-mode` | qemu-aarch64 | writable ext4 root instead of A/B images                  |

```sh
nix build .#legacyPackages.x86_64-linux.examples.service.config.system.build.runner
./result/bin/run-micro-vm a
# root / micro, then: wget -qO- http://127.0.0.1/cgi-bin/status
```

## Your own board

Start from the template: a flake with one board, a card image with its
secrets, and an SSH deploy app.

```sh
mkdir my-board && cd my-board
nix flake init -t <micro-finix flake URL>
# edit configuration.nix (and the device in flake.nix), then
nix run .#image -- my-board.img    # dd it to the card, then delete it
nix run .#deploy -- root@<board>   # later updates, A/B over SSH
```

Or call the library directly:

```nix
micro-finix.lib.microSystem {
  device = micro-finix.devices.qemu-aarch64;
  modules = [ ./configuration.nix ];
}
```

Finix service modules are opt-in: import them from the `modules`
argument, e.g. `imports = [ modules.dropbear ];`.

## Secrets

Everything in the configuration lands in the Nix store, which is
world-readable on the device and usually pushed to a binary cache.
Secrets (Wi-Fi passphrases, password hashes, tokens) are files on the
data partition instead, declared with a command that prints them. The
command runs on your machine, at image or deploy time, so it can use
whatever holds your secrets:

```nix
micro.secrets.packages = [ pkgs.buildPackages.sops ];
micro.secrets.files."iwd/MyNetwork.psk" = {
  command = "sops -d --extract '[\"wifi\"]' ${./secrets.yaml}";
  prefix = "[Security]\nPassphrase=";
  suffix = "\n";
  # mode = "0600"; uid = 0; gid = 0;   (the defaults)
};
```

| output                       | does                                                   |
|------------------------------|--------------------------------------------------------|
| `system.build.provisionImage` | `provision-image <file.img>`: disk image with the files on its data partition |
| `system.build.pushSecrets`    | `push-secrets <ssh-target>`: write them on a running board |
| `system.build.renderSecrets`  | `render-secrets <dir>`: write them to a local directory |
| `system.build.deploy`         | runs `push-secrets` before every A/B update            |

Updates never touch the data partition, so the files stay put. Point
options at them, e.g. `users.users.root.passwordFile =
"/var/lib/secrets/root.hash"`.

## Kernel

`micro.kernel.config` is applied on top of `allnoconfig`; only listed
symbols (plus `modules/kernel/base.nix`) are enabled. The build fails
if Kconfig drops a requested symbol, which usually means a missing
parent menu (`BLK_DEV`, `NET_CORE`, `MISC_FILESYSTEMS`, ...). Inspect
the result with `config.micro.kernel.configfile`.

## Trims

`overlays/micro.nix` (package level) and `modules/profile.nix` (option
defaults) remove what small boards don't need: PAM (and with it audit,
db), libcap's Go bindings, fuse, kbd/console setup, desktop setuid
wrappers, and finix's base userland (busybox replaces it; see
`micro.excludePackages`). Image mode also stubs the switch-inhibitor
check, dropping jq. Known remaining weight: userborn (Rust; its build
pulls bindgen/clang), which finix hard-wires for user creation.

## Binary cache

The flake advertises two caches in `nixConfig` (accept them when Nix
asks, or add them to your `nix.conf`):

* `micro-finix.cachix.org`: CI pushes what every user needs from each
  build on `main`: the musl cross toolchains (gcc, binutils, rustc),
  kernels and the cross-built packages, for every device. Disk images
  and other per-configuration artifacts are left out; they are quick to
  build once their parts substitute.
* `finix.cachix.org`: finix's native glibc builds.

```
substituters = https://micro-finix.cachix.org
trusted-public-keys = micro-finix.cachix.org-1:3ZWDNuYLWhRtA76dc+ZiJnFHPwr/DQgyA3MbyRfBzOo=
```

Your own configuration hits the cache as long as micro-finix's
nixpkgs pin is used (don't make it `follow` yours) and your board uses
the same device; a changed kernel config or package override rebuilds
just that part.
