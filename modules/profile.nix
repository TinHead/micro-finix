# Defaults for small systems. Everything is mkDefault (or listed in an
# option) so a config can opt back in.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.micro;
in
{
  options = {
    micro.console = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "ttyAMA0";
      description = "Serial console device; gets the kernel console and a getty.";
    };

    micro.excludePackages = lib.mkOption {
      type = with lib.types; listOf str;
      default = [
        "acl"
        "attr"
        "findutils"
        "gawk"
        "gnugrep"
        "less"
        "libcap"
        "ncurses"
        "procps"
        "time"
        "which"
      ];
      description = ''
        Package names removed from {option}`environment.systemPackages`
        (finix's base set). busybox provides the userland instead.
        Set to `[ ]` to keep finix's defaults.
      '';
    };

    # second declaration: finix declares the option, this adds the filter
    environment.systemPackages = lib.mkOption {
      apply = lib.filter (p: !(lib.elem (lib.getName p) cfg.excludePackages));
    };
  };

  config = lib.mkMerge [
    {
      services.mdevd.enable = lib.mkDefault true;

      # finit's pidfile plugin depends on its netlink plugin
      # (plugins/pidfile.c `.depends`); finix copies pidfile.so into the
      # initrd but not netlink.so, so stage 1 logged "Failed loading
      # plugin .../netlink.so". 70 KB, deps (libcap, musl) already there.
      boot.initrd.contents = [
        { source = "${config.finit.package}/lib/finit/plugins/netlink.so"; }
      ];

      environment.systemPackages = [
        (lib.lowPrio pkgs.busybox)
      ]
      # finix writes /run/current-system/sw<shellPath> into passwd but
      # never installs the shell; put every user's shell package on the
      # path so the login shell exists (lowPrio: busybox must not shadow
      # coreutils & co.)
      ++ lib.mapAttrsToList (_: u: lib.lowPrio u.shell) (
        lib.filterAttrs (_: u: u.enable && lib.types.shellPackage.check u.shell) config.users.users
      );

      # serial-only boards: no keymaps, fonts or VESA blanking (drops kbd)
      hardware.console.enable = lib.mkDefault false;

      # login and passwd use /etc/shadow directly (shadow is built
      # without PAM in overlays/micro.nix); drops linux-pam, audit, db
      security.pam.enable = lib.mkDefault false;

      boot.supportedFilesystems.fuse.enable = lib.mkDefault false;

      # setuid helpers for multi-user desktops
      security.wrappers =
        lib.genAttrs
          [
            "su"
            "sg"
            "newgrp"
            "newuidmap"
            "newgidmap"
            "passwd"
          ]
          (_: {
            enable = lib.mkDefault false;
          })
        // {
          unix_chkpwd.enable = lib.mkDefault config.security.pam.enable;
        }
        # finix always wraps mount and umount. Every wrapper takes
        # unsecvars.h from `srcOnly pkgs.glibc`, which on musl means
        # cross-building glibc (fails), so musl drops them; glibc keeps them.
        // lib.genAttrs [ "mount" "umount" ] (_: {
          enable = lib.mkDefault (!pkgs.stdenv.hostPlatform.isMusl);
        });

      assertions =
        let
          enabled = lib.attrNames (lib.filterAttrs (_: w: w.enable) config.security.wrappers);
        in
        [
          {
            assertion = !pkgs.stdenv.hostPlatform.isMusl || enabled == [ ];
            message = ''
              security.wrappers ${lib.concatStringsSep ", " enabled} enabled on a musl
              system: finix builds every wrapper against `srcOnly pkgs.glibc`, which
              cross-builds glibc with the musl toolchain and fails.
            '';
          }
        ];
    }

    # finix writes /etc/pam.d even with PAM off
    (lib.mkIf (!config.security.pam.enable) {
      security.pam.services = lib.mkForce { };

      # finix sets PATH through pam_env only; busybox login hardcodes
      # /sbin:/bin:/usr/sbin:/usr/bin, so login shells found nothing.
      # /etc/profile.d/session-vars.sh gives it to POSIX login shells.
      environment.variables.PATH = lib.mkDefault [ "/run/current-system/sw/bin" ];
    })

    (lib.mkIf (cfg.console != null) {
      boot.kernelParams = [ "console=${cfg.console},115200" ];
      services.getty.ttys = lib.mkDefault [ cfg.console ];
    })
  ];
}
