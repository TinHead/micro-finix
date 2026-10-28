# U-Boot FIT backend: the bootloader loads one FIT image holding the
# kernel, the board's device tree (with the kernel command line in
# /chosen/bootargs) and the ramdisk, and runs `bootm`. Generic over
# boards; the device supplies the DTB, the load address and, where the
# bootloader can't decompress the kernel to its link address (it would
# overwrite the image it is reading), a relocation stub.
#
# Outputs, one FIT per slot: system.build.fit.<slot> (and `fit` itself
# for the first slot), plus system.build.fitShell, which boots the
# initrd's busybox shell instead of finit (bring-up and debugging).
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.micro.boot.uboot;
  bpkgs = pkgs.buildPackages;
  cc = pkgs.stdenv.cc;
  kernel = config.boot.kernelPackages.kernel;
  arch = pkgs.stdenv.hostPlatform.linuxArch;

  # raw kernel binary, as `make vmlinux.bin` would produce it
  kernelBin = bpkgs.runCommand "micro-kernel.bin" { nativeBuildInputs = [ cc.bintools ]; } ''
    ${cc.targetPrefix}objcopy -O binary -R .reginfo -R .notes -R .note \
      -R .comment -R .mdebug -R .note.gnu.build-id -S \
      ${kernel}/vmlinux $out
  '';

  # OpenWrt-style relocation stub: runs at the FIT load address, copies
  # the kernel to its link address and jumps there
  relocated =
    bpkgs.runCommand "micro-kernel-relocated.bin"
      {
        nativeBuildInputs = [
          cc
          cc.bintools
        ];
      }
      ''
        kaddr=$(${cc.targetPrefix}readelf -lW ${kernel}/vmlinux | awk '$1 == "LOAD" { print $3; exit }')
        src=${cfg.relocator}
        ksrc=$(echo ${kernel.dev}/lib/modules/*/source)
        flags="-D__KERNEL__ -D__ASSEMBLY__ -Os -G 0 -mno-abicalls -fno-pic -mabi=32 \
          -march=mips32r2 -Wa,--trap -DCONFIG_CACHELINE_SIZE=32 -DKERNEL_ADDR=$kaddr \
          -I$ksrc/arch/mips/include -I$ksrc/arch/mips/include/uapi -I$ksrc/include -I$ksrc/include/uapi"
        ${cc.targetPrefix}gcc $flags -c -o head.o $src/head.S
        ${cc.targetPrefix}ld -static --gc-sections -no-warn-mismatch -e startup -T $src/loader.lds \
          -Ttext 0x81000000 -o loader head.o
        ${cc.targetPrefix}objcopy -O binary -R .reginfo -R .note -R .comment -R .mdebug -R .MIPS.abiflags -S loader loader.bin
        {
          dd if=loader.bin bs=32 conv=sync status=none
          size=$(stat -c %s ${kernelBin})
          printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
            $((size & 255)) $((size >> 8 & 255)) $((size >> 16 & 255)) $((size >> 24 & 255)))"
          cat ${kernelBin}
        } > $out
      '';

  payload = if cfg.relocator != null then relocated else kernelBin;

  kernelImage =
    if cfg.compression == "none" then
      payload
    else
      bpkgs.runCommand "micro-kernel.lzma" { nativeBuildInputs = [ bpkgs.xz ]; } ''
        xz --format=lzma -9 -c ${payload} > $out
      '';

  mkFit =
    name: cmdline:
    bpkgs.runCommand "micro-${name}.itb"
      {
        nativeBuildInputs = [
          bpkgs.dtc
          bpkgs.ubootTools
        ];
      }
      ''
        cp ${cfg.dtb} board.dtb
        chmod u+w board.dtb
        fdtput -p -t s board.dtb /chosen bootargs ${lib.escapeShellArg cmdline}
        cat > image.its <<EOF
        /dts-v1/;
        / {
          description = "micro-finix ${name}";
          #address-cells = <1>;
          images {
            kernel {
              data = /incbin/("${kernelImage}");
              type = "kernel";
              arch = "${arch}";
              os = "linux";
              compression = "${cfg.compression}";
              load = <${cfg.loadAddress}>;
              entry = <${cfg.loadAddress}>;
              hash { algo = "crc32"; };
            };
            fdt {
              data = /incbin/("board.dtb");
              type = "flat_dt";
              arch = "${arch}";
              compression = "none";
              hash { algo = "crc32"; };
            };
            ramdisk {
              data = /incbin/("${config.micro.boot.ramdisk}");
              type = "ramdisk";
              arch = "${arch}";
              os = "linux";
              compression = "none";
              hash { algo = "crc32"; };
            };
          };
          configurations {
            default = "conf";
            conf {
              kernel = "kernel";
              fdt = "fdt";
              ramdisk = "ramdisk";
            };
          };
        };
        EOF
        mkimage -f image.its $out
      '';

  slotName = slot: if slot == null then "default" else slot;
  fits = lib.listToAttrs (
    map (
      slot: lib.nameValuePair (slotName slot) (mkFit (slotName slot) (config.micro.boot.cmdlineFor slot))
    ) config.micro.boot.slots
  );
in
{
  options.micro.boot.uboot = {
    loadAddress = lib.mkOption {
      type = lib.types.str;
      example = "0x82000000";
      description = "Address U-Boot places the kernel image at (and jumps to).";
    };

    dtb = lib.mkOption {
      type = lib.types.path;
      description = "The board's compiled device tree; bootargs are filled in per slot.";
    };

    compression = lib.mkOption {
      type = lib.types.enum [
        "none"
        "lzma"
      ];
      default = "none";
      description = "Kernel compression inside the FIT (flash images need lzma).";
    };

    relocator = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      description = ''
        Source of a relocation stub (OpenWrt's target/linux/generic/image/relocate)
        prepended to the kernel, for bootloaders that must not decompress
        straight to the kernel's link address.
      '';
    };

    shellCmdline = lib.mkOption {
      type = lib.types.str;
      default = "${toString config.boot.kernelParams} rdinit=${pkgs.busybox}/bin/sh";
      defaultText = lib.literalExpression ''"''${toString config.boot.kernelParams} rdinit=''${pkgs.busybox}/bin/sh"'';
      description = "Command line of `fitShell`: the initrd's busybox shell instead of finit.";
    };
  };

  config = lib.mkIf (config.micro.boot.backend == "uboot-fit") {
    micro.boot.kernelFile = kernelImage;

    system.build.fit = fits.${slotName (lib.head config.micro.boot.slots)} // fits;
    system.build.fitShell = mkFit "shell" cfg.shellCmdline;
  };
}
