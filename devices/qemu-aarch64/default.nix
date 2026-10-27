# QEMU "virt" machine, 64-bit ARM. The test bed for anything aarch64
# (e.g. the Pi Zero 2 W) without hardware.
{
  platform.config = "aarch64-unknown-linux-musl";

  module = _: {
    micro.kernel.enable = true;
    micro.kernel.config = {
      PCI = "y";
      PCI_HOST_GENERIC = "y";
      VIRTIO_MENU = "y";
      VIRTIO_PCI = "y";
      VIRTIO_BLK = "y";
      VIRTIO_NET = "y";
      VIRTIO_CONSOLE = "y";
      SERIAL_AMBA_PL011 = "y";
      SERIAL_AMBA_PL011_CONSOLE = "y";
      RTC_CLASS = "y";
      RTC_DRV_PL031 = "y";
      VFAT_FS = "y";
    };

    micro.storage.device = "/dev/vda";
    micro.boot.backend = "qemu-direct";

    micro.console = "ttyAMA0";
  };
}
