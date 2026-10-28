# Raspberry Pi Zero 2 W: BCM2710A1 (4x Cortex-A53), 512 MiB, microSD on
# the sdhost controller, CYW43436 Wi-Fi on sdhci (not enabled yet).
# Mainline kernel and device tree, booted by the Pi firmware from the
# FAT partition. First bring-up: HDMI console (firmware framebuffer via
# simpledrm) and a USB keyboard on the OTG port; the mini UART on GPIO
# 14/15 (ttyS1) carries kernel messages too.
{
  # same as qemu-aarch64, so both share one cross toolchain
  platform.config = "aarch64-unknown-linux-musl";

  # the VideoCore firmware is unfree-redistributable
  nixpkgsConfig.allowUnfreePredicate = p: (p.pname or "") == "raspberrypi-firmware";

  module =
    { lib, ... }:
    {
      micro.kernel.enable = true;
      micro.kernel.config = {
        ARCH_BCM = "y";
        ARCH_BCM2835 = "y";

        MAILBOX = "y";
        BCM2835_MBOX = "y";
        RASPBERRYPI_FIRMWARE = "y";
        CLK_RASPBERRYPI = "y";
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

        # microSD on sdhost only, so it is always mmcblk0 (enabling
        # sdhci for Wi-Fi later needs mmc aliases in the DT)
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

        # USB keyboard on the OTG port (host mode)
        USB_SUPPORT = "y";
        USB = "y";
        USB_PHY = "y";
        NOP_USB_XCEIV = "y";
        USB_DWC2 = "y";
        USB_DWC2_HOST = "y";
        INPUT = "y";
        HID_SUPPORT = "y";
        HID = "y";
        HID_GENERIC = "y";
        USB_HID = "y";
      };

      # serial first, tty1 last: /dev/console (and the getty) is on HDMI
      boot.kernelParams = lib.mkBefore [ "console=ttyS1,115200" ];
      micro.console = "tty1";

      micro.storage.device = "/dev/mmcblk0";
      micro.boot.backend = "rpi-firmware";
      micro.boot.rpi = {
        dtb = "broadcom/bcm2837-rpi-zero-2-w.dtb";
        extraConfig = ''
          enable_uart=1
          disable_overscan=1
        '';
      };
    };
}
