# Storage: where the store slots, root and data live on the boot medium.
# The generic part declares partitions by name and order; a layout
# backend (only `block` so far: SD card, eMMC, virtio disk; later e.g.
# `ubi` for raw NAND) numbers them, names their devices, picks the data
# filesystem, builds the flashable image and states which update modes
# it can carry.
{
  config,
  lib,
  ...
}:
let
  cfg = config.micro.storage;

  # partition names in on-medium order (ties broken by name)
  ordered = lib.sort (
    a: b:
    let
      oa = cfg.partitions.${a}.order;
      ob = cfg.partitions.${b}.order;
    in
    oa < ob || (oa == ob && a < b)
  ) (lib.attrNames cfg.partitions);
in
{
  imports = [ ./block.nix ];

  options.micro.storage = {
    layout = lib.mkOption {
      type = lib.types.enum [ "block" ];
      default = "block";
      description = "Storage backend; see modules/storage/<layout>.nix.";
    };

    device = lib.mkOption {
      type = lib.types.str;
      example = "/dev/mmcblk0";
      description = "Whole-device name the system boots from, as the kernel names it.";
    };

    bootSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 64;
      description = "Boot partition size in MiB (backends that need one).";
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

    dataFsType = lib.mkOption {
      type = lib.types.str;
      description = "Filesystem of the data partition; the layout sets the default.";
    };

    supportedUpdateModes = lib.mkOption {
      type = with lib.types; listOf str;
      internal = true;
      description = "Update modes the layout can carry (set by the layout).";
    };

    devicePath = lib.mkOption {
      type = with lib.types; functionTo str;
      internal = true;
      description = "Partition number -> device node (set by the layout).";
    };

    partitions = lib.mkOption {
      description = "Partitions of the boot medium, filled in by the update mode and boot backend.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, config, ... }:
          {
            options = {
              order = lib.mkOption {
                type = lib.types.int;
                description = "Position on the medium relative to other partitions (lower first).";
              };
              index = lib.mkOption {
                type = lib.types.ints.positive;
                readOnly = true;
                default = 1 + lib.lists.findFirstIndex (n: n == name) null ordered;
                description = "Partition number, assigned from `order`.";
              };
              size = lib.mkOption {
                type = lib.types.ints.positive;
                description = "MiB";
              };
              type = lib.mkOption {
                type = lib.types.str;
                default = "83";
                description = "Partition type id (MBR) for the block layout.";
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
                default = cfg.devicePath config.index;
                description = "Device node of the partition on the running system.";
              };
            };
          }
        )
      );
    };
  };

  config = {
    micro.storage.partitions.data = {
      order = lib.mkDefault 90;
      size = lib.mkDefault cfg.dataSize;
    };

    assertions = [
      {
        assertion = lib.elem config.micro.update.mode cfg.supportedUpdateModes;
        message = "micro.storage.layout ${cfg.layout} does not support update mode ${config.micro.update.mode}";
      }
    ];
  };
}
