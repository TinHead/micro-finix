# Boot backends. A backend turns the kernel, initrd and per-slot command
# lines into the contents of the boot partition (and, for emulators, a
# runner). Firmware-specific files never leak outside the backend.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.micro.boot;
  bpkgs = pkgs.buildPackages;
  kernel = config.boot.kernelPackages.kernel;
in
{
  imports = [ ./qemu-direct.nix ];

  options.micro.boot = {
    backend = lib.mkOption {
      type = lib.types.enum [ "qemu-direct" ];
      description = "Which boot backend fills the boot partition.";
    };

    slots = lib.mkOption {
      type = with lib.types; listOf (nullOr str);
      internal = true;
      description = "Store slots set by the update mode; null means no slot parameter.";
    };

    cmdlineFor = lib.mkOption {
      type = with lib.types; functionTo str;
      readOnly = true;
      default =
        slot:
        toString (
          config.boot.kernelParams
          ++ [ "init=${config.system.topLevel}/init" ]
          ++ lib.optional (slot != null) "micro.slot=${slot}"
        );
      description = "Kernel command line for a slot.";
    };

    files = lib.mkOption {
      type = lib.types.package;
      description = "Directory copied to the root of the boot partition.";
    };
  };

  config = {
    micro.boot.files = lib.mkDefault (
      bpkgs.runCommand "micro-boot-files" { } ''
        mkdir $out
        cp ${kernel}/${kernel.target} $out/kernel
        cp ${config.boot.initrd.package}/initrd $out/initrd
        ${lib.concatMapStrings (slot: ''
          echo ${lib.escapeShellArg (cfg.cmdlineFor slot)} > $out/cmdline${
            lib.optionalString (slot != null) "-${slot}"
          }.txt
        '') cfg.slots}
      ''
    );

    micro.storage.partitions.boot = {
      index = 1;
      size = config.micro.storage.bootSize;
      type = "c";
      image =
        bpkgs.runCommand "micro-boot.img"
          {
            nativeBuildInputs = [
              bpkgs.dosfstools
              bpkgs.mtools
            ];
          }
          ''
            truncate -s ${toString config.micro.storage.bootSize}M $out
            mkfs.vfat -n MICRO-BOOT $out >/dev/null
            mcopy -s -i $out ${cfg.files}/* ::/
          '';
    };

    fileSystems."/boot" = {
      device = config.micro.storage.partitions.boot.device;
      fsType = "vfat";
      options = [ "noauto" ];
    };
  };
}
