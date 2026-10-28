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
  hostPlatform = pkgs.stdenv.hostPlatform;
  # the ram layout has no disk image
  hasDisk = config.micro.storage.layout != "ram";

  # headless, single-target QEMU. Stock `qemu` builds every target plus
  # gtk/SDL/spice/audio (thousands of derivations, some cross-built for
  # the guest arch via gobject-introspection). Not `minimal`: that drops
  # libslirp, which `-nic user` needs.
  qemu =
    (bpkgs.qemu.override {
      nixosTestRunner = true;
      brlttySupport = false;
      hostCpuTargets = [ "${hostPlatform.qemuArch}-softmmu" ];
    }).overrideAttrs
      (old: {
        # upstream's postInstall only links qemu-kvm to the build
        # machine's own qemu-system-*, which isn't built here (dangling
        # symlink fails noBrokenSymlinks); the runner calls the guest
        # binary directly
        postInstall = lib.throwIfNot (
          lib.trim old.postInstall
          == "ln -s $out/bin/qemu-system-${bpkgs.stdenv.hostPlatform.qemuArch} $out/bin/qemu-kvm"
        ) "qemu-direct: upstream qemu postInstall changed; re-check the qemu-kvm workaround" "";
      });

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
    else if hostPlatform.isMips32 then
      [
        "-machine"
        "malta"
        "-cpu"
        # no FPU, like MT7621's 1004Kc; matches soft-float userlands
        "24Kc"
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
      ${lib.optionalString hasDisk ''
        if [ ! -e "$state/disk.img" ]; then
          cp --reflink=auto ${config.system.build.diskImage} "$state/disk.img"
          chmod u+w "$state/disk.img"
        fi
      ''}      case "$slot" in
        ${lib.concatMapStrings (slot: ''
          ${
            if slot == null then "''" else slot
          }) cmdline=${lib.escapeShellArg (config.micro.boot.cmdlineFor slot)} ;;
        '') config.micro.boot.slots}
        *) echo "unknown slot $slot" >&2; exit 1 ;;
      esac
      exec ${qemu}/bin/qemu-system-${hostPlatform.qemuArch} \
        ${lib.escapeShellArgs machineArgs} \
        -m ${toString cfg.memory} -nographic \
        -kernel ${config.micro.boot.kernelFile} \
        -initrd ${config.micro.boot.ramdisk} \
        -append "$cmdline" \
        ${lib.optionalString hasDisk ''-drive if=virtio,format=raw,file="$state/disk.img" \''}
        -nic user,model=virtio-net-pci \
        ${lib.escapeShellArgs cfg.extraArgs} "$@"
    '';
  };
}
