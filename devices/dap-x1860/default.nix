# D-Link DAP-X1860 A1: MediaTek MT7621A (MIPS 1004Kc, 2 cores x 2
# threads, no FPU), 256 MiB RAM, 128 MiB SPI-less raw NAND behind
# MediaTek NMBM, MT7915 2.4/5 GHz Wi-Fi on PCIe. Stock bootloader is
# U-Boot ELX-v1.0.4 (FIT capable); console ttyS0 at 115200 on the 4-pin
# header (1 Tx, 2 GND, 3 Rx, 4 Vcc, 3.3 V).
#
# Mainline lacks the MT7621 NAND controller driver and NMBM; those
# come from the pinned OpenWrt tree (`microSources.openwrt`), as does
# the board's device tree. Bring-up stage: boots from RAM (U-Boot
# `bootm` of system.build.fit / fitShell); nothing is written to flash.
{
  # same ISA/ABI as qemu-mipsel (OpenWrt's mipsel_24kc), so both share
  # one cross toolchain
  platform = {
    config = "mipsel-unknown-linux-musl";
    gcc = {
      arch = "mips32r2";
      float = "soft";
    };
  };

  module =
    {
      config,
      pkgs,
      lib,
      microSources,
      ...
    }:
    let
      openwrt = microSources.openwrt;
      ramips = "${openwrt}/target/linux/ramips";
      bpkgs = pkgs.buildPackages;

      # files OpenWrt drops into the tree as whole files, as a patch
      newFile =
        name: src: path:
        bpkgs.runCommand "${name}.patch" { } ''
          diff -Nu --label /dev/null --label b/${path} /dev/null ${src} > $out || [ $? -eq 1 ]
        '';

      dtb =
        bpkgs.runCommand "dap-x1860-a1.dtb"
          {
            nativeBuildInputs = [
              bpkgs.dtc
              bpkgs.stdenv.cc
            ];
          }
          ''
            set -o pipefail
            tar -xf ${config.micro.kernel.src} --strip-components=1 --wildcards \
              '*/include/dt-bindings/*' '*/include/uapi/linux/input-event-codes.h'
            cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
              -I ${ramips}/dts -I include \
              ${ramips}/dts/mt7621_dlink_dap-x1860-a1.dts \
              | dtc -I dts -O dtb -p 4096 -o $out -
          '';
    in
    {
      micro.kernel.enable = true;
      micro.kernel.patches = [
        {
          name = "openwrt-410-mt7621-nand";
          patch = "${ramips}/patches-6.18/410-mtd-rawnand-add-driver-support-for-MT7621-nand-flash.patch";
        }
        {
          name = "openwrt-mt7621-nand-driver";
          patch =
            newFile "mt7621-nand" "${ramips}/files/drivers/mtd/nand/raw/mt7621_nand.c"
              "drivers/mtd/nand/raw/mt7621_nand.c";
        }
        {
          # the driver calls into NMBM; without MTD_NAND_MTK_BMT the
          # header's inline stubs make that a no-op (Linux then sees the
          # raw NAND; NMBM only remaps up to the end of the kernel
          # partition, which Linux doesn't write yet)
          name = "openwrt-mtk-bmt-header";
          patch =
            newFile "mtk-bmt-h" "${openwrt}/target/linux/generic/files/include/linux/mtd/mtk_bmt.h"
              "include/linux/mtd/mtk_bmt.h";
        }
      ];
      micro.kernel.config = {
        RALINK = "y";
        SOC_MT7621 = "y";
        CPU_MIPS32_R2 = "y";
        CPU_LITTLE_ENDIAN = "y";
        MIPS_MT_SMP = "y";
        MIPS_CPS = "y";
        SCHED_SMT = "y";
        NR_CPUS = "4";
        # the command line is in the DTB's /chosen/bootargs, written per
        # slot by the uboot-fit backend; ignore whatever U-Boot passes
        MIPS_CMDLINE_FROM_DTB = "y";

        CLK_MT7621 = "y";
        PINCTRL = "y";
        PINCTRL_MT7621 = "y";
        GPIOLIB = "y";
        GPIO_MT7621 = "y";
        WATCHDOG = "y";
        MT7621_WDT = "y";

        SERIAL_8250 = "y";
        SERIAL_8250_CONSOLE = "y";
        SERIAL_OF_PLATFORM = "y";

        MTD = "y";
        MTD_OF_PARTS = "y";
        MTD_RAW_NAND = "y";
        MTD_NAND_MT7621 = "y";

        ETHERNET = "y";
        NET_VENDOR_MEDIATEK = "y";
        NET_MEDIATEK_SOC = "y";
        NET_DSA = "y";
        NET_DSA_MT7530 = "y";
        NET_DSA_MT7530_MDIO = "y";
      };

      micro.console = "ttyS0";
      micro.boot.backend = "uboot-fit";
      micro.boot.uboot = {
        inherit dtb;
        # as OpenWrt: U-Boot puts the kernel at 0x82000000 (clear of the
        # image it loaded), the stub moves it to its link address
        loadAddress = "0x82000000";
        relocator = "${openwrt}/target/linux/generic/image/relocate";
      };

      # bring-up: everything from RAM
      micro.storage.layout = "ram";
    };
}
