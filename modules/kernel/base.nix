# Kconfig baseline every micro-finix system needs: finit, the finix
# initrd (zstd cpio), devtmpfs, and the usual userspace syscalls.
# Devices add their buses, drivers and console.
{
  config,
  pkgs,
  lib,
  ...
}:
{
  config.micro.kernel.config = lib.mkIf config.micro.kernel.enable (
    lib.mapAttrs (_: lib.mkDefault) {
      # modules stay possible for out-of-tree drivers; nothing is =m by default
      MODULES = "y";
      MODULE_UNLOAD = "y";

      BINFMT_ELF = "y";
      BINFMT_SCRIPT = "y";

      BLK_DEV_INITRD = "y";
      RD_ZSTD = "y";
      BLOCK = "y";
      BLK_DEV = "y";

      TTY = "y";
      UNIX98_PTYS = "y";
      PRINTK = "y";

      PROC_FS = "y";
      SYSFS = "y";
      DEVTMPFS = "y";
      TMPFS = "y";
      TMPFS_POSIX_ACL = "y";
      TMPFS_XATTR = "y";
      SHMEM = "y";

      # finit
      CGROUPS = "y";
      INOTIFY_USER = "y";
      SIGNALFD = "y";
      TIMERFD = "y";
      EVENTFD = "y";
      EPOLL = "y";
      FHANDLE = "y";
      POSIX_TIMERS = "y";
      FUTEX = "y";
      MULTIUSER = "y";
      SYSVIPC = "y";
      FILE_LOCKING = "y";
      HIGH_RES_TIMERS = "y";

      NET = "y";
      UNIX = "y";
      INET = "y";
      IPV6 = "y";
      PACKET = "y";
      NETDEVICES = "y";
      NET_CORE = "y";

      FW_LOADER = "y";
      FW_LOADER_USER_HELPER = "n";

      EXT4_FS = "y";

      IKCONFIG = "y";
      IKCONFIG_PROC = "y";
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.is32bit {
      # 32-bit musl calls the legacy time32 syscalls (ppoll, nanosleep,
      # clock_gettime, ...) whenever the value fits in 32 bits; without
      # these they fail with ENOSYS (mdevd: "unable to iopause", sleep
      # returning at once) and stage 1 hangs at coldplug.
      COMPAT_32BIT_TIME = "y";
    }
  );
}
