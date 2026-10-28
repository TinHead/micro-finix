# Raspberry Pi firmware backend: the VideoCore firmware on the FAT boot
# partition reads config.txt and loads kernel, initrd and device tree
# itself. Everything Pi-specific (firmware blobs, config.txt) stays
# here.
#
# Slots: one cmdline-<slot>.txt per slot; config.txt's `cmdline=` picks
# the one to boot (first slot by default). Switching slots means
# rewriting config.txt; tryboot-based A/B is future work.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.micro.boot.rpi;
  boot = config.micro.boot;
  bpkgs = pkgs.buildPackages;
  kernel = config.boot.kernelPackages.kernel;
  slotFile = slot: "cmdline${lib.optionalString (slot != null) "-${slot}"}.txt";

  configTxt = pkgs.writeText "config.txt" ''
    arm_64bit=${if pkgs.stdenv.hostPlatform.is64bit then "1" else "0"}
    kernel=kernel.img
    initramfs initrd followkernel
    device_tree=${baseNameOf cfg.dtb}
    cmdline=${slotFile (lib.head boot.slots)}
    ${cfg.extraConfig}
  '';
in
{
  options.micro.boot.rpi = {
    dtb = lib.mkOption {
      type = lib.types.str;
      example = "broadcom/bcm2837-rpi-zero-2-w.dtb";
      description = "Device tree, relative to the kernel's dtbs directory.";
    };

    firmware = lib.mkOption {
      type = lib.types.package;
      default = bpkgs.raspberrypifw;
      defaultText = lib.literalExpression "pkgs.buildPackages.raspberrypifw";
      description = "Raspberry Pi firmware (bootcode.bin, start*.elf, fixup*.dat).";
    };

    dtbFixup = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''fdtput -t s "$dtb" /aliases mmc0 /soc/mmc@7e202000'';
      description = "Shell run on a copy of the DTB (`$dtb`, fdtput/fdtget on PATH) before it goes on the boot partition.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra config.txt lines.";
    };
  };

  config = lib.mkIf (boot.backend == "rpi-firmware") {
    micro.boot.partition.enable = true;

    micro.boot.files = bpkgs.runCommand "micro-rpi-boot" { nativeBuildInputs = [ bpkgs.dtc ]; } ''
      mkdir $out
      fw=${cfg.firmware}/share/raspberrypi/boot
      # firmware only: the repo's own kernels, overlays and DTBs stay out
      cp $fw/bootcode.bin $fw/start*.elf $fw/fixup*.dat $fw/LICENCE.broadcom $out/
      cp ${boot.kernelFile} $out/kernel.img
      cp ${boot.ramdisk} $out/initrd
      dtb=$out/${baseNameOf cfg.dtb}
      cp ${kernel}/dtbs/${cfg.dtb} $dtb
      chmod u+w $dtb
      ${cfg.dtbFixup}
      cp ${configTxt} $out/config.txt
      ${lib.concatMapStrings (slot: ''
        echo ${lib.escapeShellArg (boot.cmdlineFor slot)} > $out/${slotFile slot}
      '') boot.slots}
    '';
  };
}
