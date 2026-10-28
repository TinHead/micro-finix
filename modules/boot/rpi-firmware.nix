# Raspberry Pi firmware backend: the VideoCore firmware on the FAT boot
# partition reads config.txt and loads kernel, initrd and device tree
# itself. Everything Pi-specific (firmware blobs, config.txt) stays
# here.
#
# Slots: each slot's boot files live in their own directory (a/, b/:
# kernel.img, initrd, DTB, cmdline.txt, plus the config.txt that boots
# it); the top-level config.txt's `os_prefix=` picks the directory the
# firmware loads from. Updates write the inactive slot's directory and
# switch by copying its config.txt to the top (micro.boot.update), so
# config.txt changes ship with the slot. The firmware blobs are shared.
# Closure mode has a single unnamed slot: no prefix.
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
  prefix = slot: lib.optionalString (slot != null) "${slot}/";

  configTxt =
    slot:
    pkgs.writeText "config.txt" ''
      arm_64bit=${if pkgs.stdenv.hostPlatform.is64bit then "1" else "0"}
      os_prefix=${prefix slot}
      kernel=kernel.img
      initramfs initrd followkernel
      device_tree=${baseNameOf cfg.dtb}
      ${cfg.extraConfig}
    '';

  dtb = bpkgs.runCommand (baseNameOf cfg.dtb) { nativeBuildInputs = [ bpkgs.dtc ]; } ''
    dtb=$out
    cp ${kernel}/dtbs/${cfg.dtb} $dtb
    chmod u+w $dtb
    ${cfg.dtbFixup}
  '';

  # what the firmware loads for one slot, relative to os_prefix
  slotFiles =
    slot:
    bpkgs.runCommand "micro-rpi-slot${lib.optionalString (slot != null) "-${slot}"}" { } ''
      mkdir $out
      cp ${boot.kernelFile} $out/kernel.img
      cp ${boot.ramdisk} $out/initrd
      cp ${dtb} $out/${baseNameOf cfg.dtb}
      echo ${lib.escapeShellArg (boot.cmdlineFor slot)} > $out/cmdline.txt
      cp ${configTxt slot} $out/config.txt
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

    firmwareFiles = lib.mkOption {
      type = with lib.types; listOf str;
      default = [
        "bootcode.bin"
        "start*.elf"
        "fixup*.dat"
      ];
      example = [
        "bootcode.bin"
        "start.elf"
        "fixup.dat"
      ];
      description = ''
        Firmware files (globs) copied to the boot partition. All variants
        by default (~23 MiB); a board lists the ones it boots with, leaving
        room for two slots' kernels and initrds.
      '';
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

    micro.boot.files = bpkgs.runCommand "micro-rpi-boot" { } ''
      mkdir $out
      fw=${cfg.firmware}/share/raspberrypi/boot
      # firmware only: the repo's own kernels, overlays and DTBs stay out
      (cd $fw && cp ${lib.concatStringsSep " " cfg.firmwareFiles} LICENCE.broadcom $out/)
      cp ${configTxt (lib.head boot.slots)} $out/config.txt
      ${lib.concatMapStrings (slot: ''
        mkdir -p $out/${prefix slot}
        cp ${slotFiles slot}/* $out/${prefix slot}
      '') boot.slots}
    '';

    micro.boot.update = {
      inherit slotFiles;
      # $slot, $src (directory with that slot's files); /boot is mounted.
      # Write next to the old copy, then swap, so a power cut leaves
      # either the old or the new directory
      writeBoot = ''
        # pre-slot-directory layout (kernel.img etc. at the top): drop it
        # once config.txt boots from a slot directory
        if grep -q '^os_prefix=.' /boot/config.txt; then
          rm -f /boot/kernel.img /boot/initrd /boot/cmdline*.txt
        fi
        rm -rf "/boot/$slot.new"
        cp -r "$src" "/boot/$slot.new"
        sync
        rm -rf "/boot/$slot"
        mv "/boot/$slot.new" "/boot/$slot"
        sync
      '';
      switch = ''
        [ -f "/boot/$slot/config.txt" ] || { echo "no boot files for slot $slot" >&2; exit 1; }
        cp "/boot/$slot/config.txt" /boot/config.txt.new
        sync
        mv /boot/config.txt.new /boot/config.txt
        sync
      '';
    };
  };
}
