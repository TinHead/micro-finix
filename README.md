# micro-finix

[finix](https://github.com/finix-community/finix) (finit as pid 1,
NixOS-shaped modules) built the way [Liminix](https://www.liminix.org/)
builds router firmware: cross-compiled musl userland, a minimal kernel
from an attrset of Kconfig symbols, and flashable disk images.

The core is hardware-agnostic. Everything that depends on the board is
a backend selected by options:

| concern       | option                     | backends today            |
|---------------|----------------------------|---------------------------|
| CPU / libc    | device `platform`          | any nixpkgs `crossSystem` |
| kernel        | `micro.kernel.*`           | allnoconfig + attrset     |
| boot          | `micro.boot.backend`       | `qemu-direct`             |
| storage       | `micro.storage.layout`     | `block` (MBR)             |
| updates       | `micro.update.mode`        | `image`, `closure`        |

## Layout

```
flake.nix               lib.microSystem, devices, example builds
lib/micro-system.nix    evaluates finix + micro modules on a cross pkgs set
modules/kernel/         Kconfig attrset -> allnoconfig .config -> kernel
modules/update.nix      image (A/B squashfs) vs closure (ext4) mode
modules/storage/        partition table + raw disk image assembly
modules/boot/           boot backends (boot partition contents, runners)
devices/<name>/         platform triple + hardware module
examples/               example system configurations
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

# your own system
micro-finix.lib.microSystem {
  device = micro-finix.devices.qemu-aarch64;
  modules = [ ./configuration.nix ];
}
```

Finix service modules are opt-in: import them from the `modules`
argument, e.g. `imports = [ modules.dropbear ];`.

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

The flake advertises `cache.darker.ro/darker`; CI pushes every build
from `main` there. The cache is only reachable from the home network,
so builds elsewhere fall back to building locally.
