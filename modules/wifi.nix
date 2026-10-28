# Opt-in Wi-Fi client: iwd (DHCP built in, no separate client), the
# D-Bus system bus and syslogd it depends on, and the kernel side
# (cfg80211 plus the crypto iwd uses through AF_ALG and keyctl). The
# device supplies the radio driver and firmware.
#
# Credentials stay on the device: provision once with `iwctl station
# wlan0 connect <ssid>`; iwd keeps them in /var/lib/iwd, which lives on
# the persistent data partition.
{
  config,
  pkgs,
  lib,
  modules,
  ...
}:
let
  cfg = config.micro.wifi.client;
in
{
  imports = [
    # dbus is in finix's default module set
    modules.iwd
    modules.sysklogd
  ];

  options.micro.wifi.client.enable = lib.mkEnableOption "the iwd Wi-Fi client";

  config = lib.mkIf cfg.enable {
    services.iwd.enable = true;
    services.dbus.enable = true;
    services.sysklogd.enable = true;

    # cfg80211 looks for regulatory.db; without it only the world domain.
    # With a built-in cfg80211 that happens during boot, so the initrd
    # carries it too. finix's initrd /lib is a symlink into the modules
    # store path, so early firmware goes to /firmware and the loader is
    # pointed there until activation resets the path to hardware.firmware
    # (devices add their radio's files under /firmware too).
    hardware.firmware = [ pkgs.wireless-regdb ];
    boot.kernelParams = [ "firmware_class.path=/firmware" ];
    boot.initrd.contents =
      map
        (f: {
          source = "${pkgs.wireless-regdb}/lib/firmware/${f}";
          target = "/firmware/${f}";
        })
        [
          "regulatory.db"
          "regulatory.db.p7s"
        ];

    # bus activation only; iwd runs as a finit service. The wrapper
    # would cross-build glibc on musl (see the wrapper note in profile.nix)
    security.wrappers.dbus-daemon-launch-helper.enable = lib.mkDefault (
      !pkgs.stdenv.hostPlatform.isMusl
    );

    micro.kernel.config = lib.mkIf config.micro.kernel.enable (
      lib.mapAttrs (_: lib.mkDefault) {
        WIRELESS = "y";
        CFG80211 = "y";
        RFKILL = "y";

        # iwd's crypto, used via AF_ALG and keyctl (iwd checks at start)
        KEYS = "y";
        KEY_DH_OPERATIONS = "y";
        CRYPTO_USER_API_HASH = "y";
        CRYPTO_USER_API_SKCIPHER = "y";
        CRYPTO_AES = "y";
        CRYPTO_CBC = "y";
        CRYPTO_ECB = "y";
        CRYPTO_DES = "y";
        CRYPTO_CMAC = "y";
        CRYPTO_HMAC = "y";
        CRYPTO_MD4 = "y";
        CRYPTO_MD5 = "y";
        CRYPTO_SHA1 = "y";
        CRYPTO_SHA256 = "y";
        CRYPTO_SHA512 = "y";
      }
    );
  };
}
