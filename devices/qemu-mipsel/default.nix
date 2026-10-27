# QEMU "malta" board, 32-bit little-endian MIPS. The test bed for MT7621
# routers (EdgeRouter X, DAP-X1860) without touching them: same ISA and
# ABI as OpenWrt's mipsel_24kc (MIPS32r2, soft-float; the 1004Kc cores
# have no FPU), 256 MiB like the ER-X. Board support (MT7621 SoC, NAND,
# U-Boot) belongs to the real router devices, not here.
{
  platform = {
    config = "mipsel-unknown-linux-musl";
    gcc = {
      arch = "mips32r2";
      float = "soft";
    };
  };

  module = _: {
    micro.kernel.enable = true;
    micro.kernel.config = {
      MIPS_MALTA = "y";
      CPU_MIPS32_R2 = "y";
      CPU_LITTLE_ENDIAN = "y";

      PCI = "y";
      VIRTIO_MENU = "y";
      VIRTIO_PCI = "y";
      VIRTIO_BLK = "y";
      VIRTIO_NET = "y";

      SERIAL_8250 = "y";
      SERIAL_8250_CONSOLE = "y";
      RTC_CLASS = "y";
    };

    micro.storage.device = "/dev/vda";
    micro.boot.backend = "qemu-direct";
    micro.boot.qemu.memory = 256;

    micro.console = "ttyS0";
  };
}
