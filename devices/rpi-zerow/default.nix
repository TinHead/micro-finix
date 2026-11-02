# Raspberry Pi Zero W: BCM2835 (1x ARM1176JZF-S, ARMv6 + VFPv2), 512
# MiB, microSD on the sdhost controller, CYW43430 Wi-Fi on sdhci (SDIO,
# brcmfmac; used when micro.wifi.client is enabled).
# Same board layout as the Zero 2 W (sdhost/sdhci, mini UART on GPIO
# 14/15 as ttyS1, dwc2 OTG on the data port, firmware boot), so this
# mirrors devices/rpi-zero2w; the differences are the 32-bit ARMv6
# platform (zImage, hard-float VFPv2 userspace) and the radio firmware.
{
  # nixpkgs' pkgsCross.muslpi (raspberryPi platform: armv6kz, vfpv2)
  platform = {
    config = "armv6l-unknown-linux-musleabihf";
    gcc = {
      arch = "armv6kz";
      fpu = "vfpv2";
    };
  };

  # userborn's cross rustc (see the file)
  overlays = [ (import ./rustc-armv6.nix) ];

  # the VideoCore and Wi-Fi firmware are unfree-redistributable
  nixpkgsConfig.allowUnfreePredicate =
    p:
    builtins.elem (p.pname or "") [
      "raspberrypi-firmware"
      "raspberrypi-wireless-firmware"
    ];

  module =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      # only this board's radio files (CYW43430 = brcmfmac43430), out of
      # the whole Pi wireless firmware set; the driver asks for
      # <chip>-sdio.raspberrypi,model-zero-w.* first
      wifiFirmware = pkgs.buildPackages.runCommand "rpi-zerow-wifi-firmware" { } ''
        mkdir -p $out/lib/firmware/brcm
        cp -L ${pkgs.raspberrypiWirelessFirmware}/lib/firmware/brcm/brcmfmac*-sdio.raspberrypi,model-zero-w.* $out/lib/firmware/brcm/
      '';
    in
    {
      micro.kernel.enable = true;
      micro.kernel.config = {
        # 32-bit ARM: allnoconfig turns off the MMU (and with it the
        # multiplatform machine list), VFP (hard-float userspace dies on
        # its first FP instruction) and the kuser helpers page
        MMU = "y";
        ARCH_MULTI_V6 = "y";
        AEABI = "y";
        VFP = "y";
        KUSER_HELPERS = "y";

        ARCH_BCM = "y";
        ARCH_BCM2835 = "y";

        MAILBOX = "y";
        BCM2835_MBOX = "y";
        RASPBERRYPI_FIRMWARE = "y";
        CLK_RASPBERRYPI = "y";
        # cprman + aux clocks; without it sdhost (SD card) and the mini
        # UART defer forever ("could not get clk")
        CLK_BCM2835 = "y";
        PINCTRL_BCM2835 = "y";
        DMADEVICES = "y";
        DMA_BCM2835 = "y";
        # power domains (USB, HDMI) via the firmware need PM
        PM = "y";
        RASPBERRYPI_POWER = "y";
        WATCHDOG = "y";
        BCM2835_WDT = "y";

        SERIAL_8250 = "y";
        SERIAL_8250_CONSOLE = "y";
        SERIAL_8250_EXTENDED = "y";
        SERIAL_8250_SHARE_IRQ = "y";
        SERIAL_8250_BCM2835AUX = "y";
        SERIAL_AMBA_PL011 = "y";
        SERIAL_AMBA_PL011_CONSOLE = "y";

        # microSD on sdhost; mmc aliases in the DTB (below) keep it
        # mmcblk0 once sdhci (Wi-Fi) probes too
        MMC = "y";
        MMC_BLOCK = "y";
        MMC_BCM2835 = "y";
        VFAT_FS = "y";

        # HDMI: the firmware's framebuffer, console on it
        DRM = "y";
        DRM_SIMPLEDRM = "y";
        DRM_FBDEV_EMULATION = "y";
        VT = "y";
        VT_CONSOLE = "y";
        FRAMEBUFFER_CONSOLE = "y";

        # USB gadget serial on the data port (ttyGS0 here, /dev/ttyACM0
        # on the PC): console + getty without HDMI or a UART adapter
        USB_SUPPORT = "y";
        USB_GADGET = "y";
        USB_PHY = "y";
        NOP_USB_XCEIV = "y";
        USB_DWC2 = "y";
        USB_DWC2_PERIPHERAL = "y";
        USB_G_SERIAL = "y";
        U_SERIAL_CONSOLE = "y";

        # ACT LED: the DT sets the heartbeat trigger
        NEW_LEDS = "y";
        LEDS_CLASS = "y";
        LEDS_GPIO = "y";
        LEDS_TRIGGERS = "y";
        LEDS_TRIGGER_HEARTBEAT = "y";
      };

      # Wi-Fi radio: SDIO on sdhci, brcmfmac; only with cfg80211 (the
      # micro.wifi.client profile)
      micro.kernel.conditionalConfig.CFG80211 = {
        MMC_SDHCI = "y";
        MMC_SDHCI_PLTFM = "y";
        MMC_SDHCI_IPROC = "y";
        PWRSEQ_SIMPLE = "y";
        WLAN = "y";
        WLAN_VENDOR_BROADCOM = "y";
        BRCMFMAC = "y";
        BRCMFMAC_SDIO = "y";
      };
      hardware.firmware = lib.mkIf config.micro.wifi.client.enable [ wifiFirmware ];
      # brcmfmac is built in and requests its firmware while probing,
      # before the real root is mounted; the initrd carries it in
      # /firmware (see modules/wifi.nix)
      boot.initrd.contents = lib.mkIf config.micro.wifi.client.enable [
        {
          source = "${wifiFirmware}/lib/firmware/brcm";
          target = "/firmware/brcm";
        }
      ];

      # serial and HDMI get kernel messages too; /dev/console is the last
      # one, the USB gadget port
      boot.kernelParams = lib.mkBefore [
        "console=ttyS1,115200"
        "console=tty1"
      ];
      micro.console = "ttyGS0";
      services.getty.ttys = [
        "ttyGS0"
        "tty1"
      ];

      micro.storage.device = "/dev/mmcblk0";
      micro.boot.backend = "rpi-firmware";
      micro.boot.rpi = {
        # 32-bit ARM installs its DTBs flat (no vendor directory)
        dtb = "bcm2835-rpi-zero-w.dtb";
        # BCM2835: start.elf/fixup.dat only (no start4*: Pi 4; _x/_cd/_db:
        # camera, cut-down, debug variants)
        firmwareFiles = [
          "bootcode.bin"
          "start.elf"
          "fixup.dat"
        ];
        # the mainline DT has no mmc aliases; pin SD to mmc0, Wi-Fi to mmc1
        dtbFixup = ''
          fdtput -p -t s "$dtb" /aliases mmc0 /soc/mmc@7e202000
          fdtput -t s "$dtb" /aliases mmc1 /soc/mmc@7e300000
        '';
        extraConfig = ''
          enable_uart=1
          disable_overscan=1
        '';
      };
    };
}
