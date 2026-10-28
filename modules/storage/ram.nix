# RAM layout: the whole system comes in with the boot image, nothing is
# read from or written to storage. The squashfs store travels as a
# second cpio archive appended to the initrd (the kernel unpacks
# concatenated archives); stage 1 mounts it from that file. The data
# "partition" is a tmpfs, so nothing persists. For bring-up on new
# hardware (boot from RAM via the bootloader) and netboot-style tests.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.micro.storage;
  bpkgs = pkgs.buildPackages;
  storeFile = "/micro-store.squashfs";
in
{
  config = lib.mkIf (cfg.layout == "ram") {
    micro.storage = {
      supportedUpdateModes = [ "image" ];

      # both slots are the store file; data lives on a tmpfs
      devicePath = { name, ... }: if name == "data" then "tmpfs" else storeFile;
      dataFsType = "tmpfs";
    };

    # util-linux mount sets up a loop device for a regular file
    micro.kernel.config = lib.mkIf config.micro.kernel.enable {
      BLK_DEV_LOOP = lib.mkDefault "y";
    };

    micro.boot.ramdisk =
      bpkgs.runCommand "micro-ramdisk"
        {
          nativeBuildInputs = [ bpkgs.cpio ];
        }
        ''
          mkdir root
          cp ${config.system.build.storeImage} root${storeFile}
          cp ${config.boot.initrd.package}/initrd $out
          chmod u+w $out
          # the kernel skips zero padding between archives but wants each
          # cpio header 4-byte aligned
          truncate -s %512 $out
          (cd root && find . -mindepth 1 | cpio -o -H newc -R +0:+0 --quiet) >> $out
        '';
  };
}
