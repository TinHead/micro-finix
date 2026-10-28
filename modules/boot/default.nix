# Boot backends. A backend decides which kernel artifact it boots
# (`kernelFile`), whether it needs a boot partition, what goes on it
# (`files`), and for emulators provides a runner. Firmware-specific files
# never leak outside the backend.
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
  imports = [
    ./qemu-direct.nix
    ./uboot-fit.nix
    ./rpi-firmware.nix
  ];

  options.micro.boot = {
    backend = lib.mkOption {
      type = lib.types.enum [
        "qemu-direct"
        "uboot-fit"
        "rpi-firmware"
      ];
      description = "How the device loads the kernel; see modules/boot/<backend>.nix.";
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

    kernelFile = lib.mkOption {
      type = lib.types.path;
      default = "${kernel}/${kernel.target}";
      defaultText = lib.literalExpression ''"''${kernel}/''${kernel.target}"'';
      description = ''
        The kernel artifact the backend boots. Defaults to the platform's
        kernel target (`Image`, `zImage`, `vmlinux`, ...); backends that
        need a wrapped format (uImage, FIT) set their own.
      '';
    };

    files = lib.mkOption {
      type = lib.types.package;
      description = "Directory copied to the root of the boot partition.";
    };

    ramdisk = lib.mkOption {
      type = lib.types.path;
      default = "${config.boot.initrd.package}/initrd";
      defaultText = lib.literalExpression ''"''${config.boot.initrd.package}/initrd"'';
      description = ''
        The initrd file the backend loads. The finix initrd by default;
        storage layouts that carry more in RAM (e.g. `ram`) extend it.
      '';
    };

    partition = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether the backend needs a FAT boot partition (firmware that
          reads kernel and config from a filesystem, e.g. the Pi). Set by
          the backend.
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
      micro.boot.files = lib.mkDefault (
        bpkgs.runCommand "micro-boot-files" { } ''
          mkdir $out
          cp ${cfg.kernelFile} $out/kernel
          cp ${cfg.ramdisk} $out/initrd
          ${lib.concatMapStrings (slot: ''
            echo ${lib.escapeShellArg (cfg.cmdlineFor slot)} > $out/cmdline${
              lib.optionalString (slot != null) "-${slot}"
            }.txt
          '') cfg.slots}
        ''
      );
    }

    (lib.mkIf cfg.partition.enable {
      micro.storage.partitions.boot = {
        order = 10;
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
    })
  ];
}
