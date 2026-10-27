# QEMU loads kernel and initrd directly (-kernel/-initrd/-append); the
# disk carries the store and data partitions. `system.build.runner`
# boots a scratch copy of the disk image.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.micro.boot.qemu;
  bpkgs = pkgs.buildPackages;
  kernel = config.boot.kernelPackages.kernel;
  hostPlatform = pkgs.stdenv.hostPlatform;

  machineArgs =
    if hostPlatform.isAarch64 then
      [
        "-machine"
        "virt"
        "-cpu"
        "cortex-a53"
      ]
    else if hostPlatform.isAarch32 then
      [
        "-machine"
        "virt"
        "-cpu"
        "cortex-a7"
      ]
    else if hostPlatform.isRiscV64 then
      [
        "-machine"
        "virt"
      ]
    else if hostPlatform.isx86_64 then
      [
        "-machine"
        "q35,accel=kvm:tcg"
      ]
    else
      throw "qemu-direct: no machine defined for ${hostPlatform.system}";
in
{
  options.micro.boot.qemu = {
    memory = lib.mkOption {
      type = lib.types.ints.positive;
      default = 512;
      description = "Guest RAM in MiB (default matches a Pi Zero 2 W).";
    };
    extraArgs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
    };
  };

  config = lib.mkIf (config.micro.boot.backend == "qemu-direct") {
    system.build.runner = bpkgs.writeShellScriptBin "run-micro-vm" ''
      # usage: run-micro-vm [slot] [extra qemu args...]
      set -eu
      slot=''${1:-${toString (lib.head config.micro.boot.slots)}}
      [ $# -gt 0 ] && shift
      state=''${MICRO_VM_STATE:-$PWD/micro-vm}
      mkdir -p "$state"
      if [ ! -e "$state/disk.img" ]; then
        cp --reflink=auto ${config.system.build.diskImage} "$state/disk.img"
        chmod u+w "$state/disk.img"
      fi
      case "$slot" in
        ${lib.concatMapStrings (slot: ''
          ${
            if slot == null then "''" else slot
          }) cmdline=${lib.escapeShellArg (config.micro.boot.cmdlineFor slot)} ;;
        '') config.micro.boot.slots}
        *) echo "unknown slot $slot" >&2; exit 1 ;;
      esac
      exec ${bpkgs.qemu}/bin/qemu-system-${hostPlatform.qemuArch} \
        ${lib.escapeShellArgs machineArgs} \
        -m ${toString cfg.memory} -nographic \
        -kernel ${kernel}/${kernel.target} \
        -initrd ${config.boot.initrd.package}/initrd \
        -append "$cmdline" \
        -drive if=virtio,format=raw,file="$state/disk.img" \
        -nic user,model=virtio-net-pci \
        ${lib.escapeShellArgs cfg.extraArgs} "$@"
    '';
  };
}
