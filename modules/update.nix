# Update model. Both modes boot the same finix toplevel and run finix
# activation on every boot; they differ in how the store is packaged.
#
#   image    tmpfs root, read-only squashfs /nix/store in one of two A/B
#            slots chosen by `micro.slot=a|b` on the kernel command line.
#            Updates write the inactive slot.
#   closure  writable ext4 root holding /nix/store. Updates copy a new
#            closure and switch.
#
# Both keep service state on a separate data partition that is never
# rewritten by an update.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.micro.update;
  storage = config.micro.storage;
  toplevel = config.system.topLevel;

  deviceConditions =
    lib.optionals config.services.mdevd.enable [ "run/coldplug/success" ]
    ++ lib.optionals config.services.udev.enable [ "run/udevadm:5/success" ];

  storeImage = pkgs.callPackage (pkgs.path + "/nixos/lib/make-squashfs.nix") {
    storeContents = [ toplevel ];
    comp = cfg.squashfsCompression;
  };

  rootImage = pkgs.callPackage (pkgs.path + "/nixos/lib/make-ext4-fs.nix") {
    storePaths = [ toplevel ];
    volumeLabel = "micro-root";
  };
in
{
  options.micro.update = {
    mode = lib.mkOption {
      type = lib.types.enum [
        "image"
        "closure"
      ];
      default = "image";
      description = "How the system is stored and updated; see the comment in modules/update.nix.";
    };

    squashfsCompression = lib.mkOption {
      type = lib.types.str;
      default = "zstd -Xcompression-level 19";
      description = "mksquashfs `-comp` argument for the image-mode store.";
    };

    dataMountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib";
      description = "Where the persistent data partition is mounted.";
    };
  };

  config = lib.mkMerge [
    {
      micro.kernel.config = lib.mkIf config.micro.kernel.enable (
        if cfg.mode == "image" then
          {
            MISC_FILESYSTEMS = "y";
            SQUASHFS = "y";
            SQUASHFS_ZSTD = "y";
          }
        else
          { }
      );

      fileSystems.${cfg.dataMountPoint} = {
        device = storage.partitions.data.device;
        fsType = "ext4";
        neededForBoot = true;
      };
    }

    (lib.mkIf (cfg.mode == "image") {
      fileSystems."/" = {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "mode=755" ];
      };
      fileSystems."/nix/store" = {
        device = "/dev/micro/store";
        fsType = "squashfs";
        options = [ "ro" ];
        neededForBoot = true;
      };

      # resolve the slot from the command line before the store is mounted;
      # finix's wait-dev task polls until /dev/micro/store appears
      boot.initrd.finit.tasks.micro-slot = {
        conditions = deviceConditions;
        script = ''
          slot=a
          for o in $(cat /proc/cmdline); do
            case "$o" in micro.slot=*) slot=''${o#micro.slot=} ;; esac
          done
          case "$slot" in
            a) dev=${storage.partitions.root-a.device} ;;
            b) dev=${storage.partitions.root-b.device} ;;
            *) echo "micro-slot: unknown slot '$slot'" >&2; exit 1 ;;
          esac
          mkdir -p /dev/micro
          ln -sfn "$dev" /dev/micro/store
          echo "micro-slot: booting slot $slot from $dev"
        '';
      };

      micro.storage.partitions = {
        root-a = {
          index = 2;
          size = storage.slotSize;
          image = storeImage;
        };
        root-b = {
          index = 3;
          size = storage.slotSize;
          image = null;
        };
        data.index = 4;
      };

      micro.boot.slots = [
        "a"
        "b"
      ];
      system.build.storeImage = storeImage;
    })

    (lib.mkIf (cfg.mode == "closure") {
      fileSystems."/" = {
        device = storage.partitions.root.device;
        fsType = "ext4";
      };

      micro.storage.partitions = {
        root = {
          index = 2;
          size = storage.rootSize;
          image = rootImage;
        };
        data.index = 3;
      };

      micro.boot.slots = [ null ];
      system.build.rootImage = rootImage;
    })
  ];
}
