# Storage layout. Only `block` (SD card, eMMC, virtio disk) exists so
# far; raw-flash layouts (UBI, JFFS2) would add their own backends and
# declare which update modes they support.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.micro.storage;

  # /dev/vda -> /dev/vda2, /dev/mmcblk0 -> /dev/mmcblk0p2
  partitionPath =
    index:
    let
      last = lib.substring (lib.stringLength cfg.device - 1) 1 cfg.device;
      sep = if builtins.match "[0-9]" last != null then "p" else "";
    in
    "${cfg.device}${sep}${toString index}";
in
{
  imports = [ ./disk-image.nix ];

  options.micro.storage = {
    layout = lib.mkOption {
      type = lib.types.enum [ "block" ];
      default = "block";
    };

    device = lib.mkOption {
      type = lib.types.str;
      example = "/dev/mmcblk0";
      description = "Whole-disk device the system boots from, as the kernel names it.";
    };

    bootSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 64;
      description = "Boot (FAT) partition size in MiB.";
    };

    slotSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 256;
      description = "Size of each A/B store slot in MiB (image mode). Leave headroom for growth.";
    };

    rootSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1024;
      description = "Root partition size in MiB (closure mode).";
    };

    dataSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 64;
      description = "Initial data partition size in MiB.";
    };

    partitions = lib.mkOption {
      description = "Partitions of the boot disk, filled in by the update mode and boot backend.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }:
          {
            options = {
              index = lib.mkOption { type = lib.types.ints.positive; };
              size = lib.mkOption {
                type = lib.types.ints.positive;
                description = "MiB";
              };
              type = lib.mkOption {
                type = lib.types.str;
                default = "83";
                description = "MBR partition type id.";
              };
              image = lib.mkOption {
                type = with lib.types; nullOr package;
                default = null;
                description = "Filesystem image written into the partition; null leaves it empty.";
              };
              growFilesystem = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Grow the (ext2/3/4) filesystem image to the full partition
                  size when assembling the disk image. Image builders size
                  filesystems to their contents; without this the rest of
                  the partition stays unused.
                '';
              };
              device = lib.mkOption {
                type = lib.types.str;
                readOnly = true;
                default = partitionPath config.index;
              };
            };
          }
        )
      );
    };
  };

  config = {
    micro.storage.partitions.data = {
      size = lib.mkDefault cfg.dataSize;
      image = lib.mkDefault (
        pkgs.buildPackages.runCommand "micro-data.img"
          { nativeBuildInputs = [ pkgs.buildPackages.e2fsprogs ]; }
          ''
            truncate -s ${toString cfg.dataSize}M $out
            mkfs.ext4 -q -F -L micro-data $out
          ''
      );
    };

    assertions =
      let
        indexes = lib.mapAttrsToList (_: p: p.index) cfg.partitions;
      in
      [
        {
          assertion = lib.length indexes == lib.length (lib.unique indexes);
          message = "micro.storage.partitions: duplicate partition index";
        }
        {
          assertion = lib.sort lib.lessThan indexes == lib.range 1 (lib.length indexes);
          message = "micro.storage.partitions: indexes must be contiguous from 1";
        }
        {
          assertion = lib.all (i: i <= 4) indexes;
          message = "micro.storage.partitions: MBR allows at most 4 primary partitions";
        }
      ];
  };
}
