# Clock sync with busybox ntpd (already on the system, no extra
# closure). The boards have no RTC and RTC_HCTOSYS is off, so the clock
# starts at 2000 on every boot; ntpd steps it on the first answer
# (offset > 1 s) and slews after that. Server names are re-resolved
# until they resolve, so starting before the network (or DNS) is up is
# fine. For a full NTP daemon, import finix's `modules.chronyd` instead.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.micro.ntp;
  syslog = config.services.sysklogd.enable;
  isIP = s: builtins.match "[0-9.]+|.*:.*" s != null;
in
{
  options.micro.ntp = {
    enable = lib.mkEnableOption "NTP time sync with busybox ntpd";

    servers = lib.mkOption {
      type = with lib.types; nonEmptyListOf str;
      default = [
        "0.pool.ntp.org"
        "1.pool.ntp.org"
        "2.pool.ntp.org"
        "3.pool.ntp.org"
      ];
      description = "NTP servers (names or addresses) to sync from.";
    };

    package = lib.mkPackageOption pkgs "busybox" { };
  };

  config = lib.mkIf cfg.enable {
    finit.services.ntpd = {
      description = "busybox ntpd";
      conditions = lib.mkIf syslog "service/syslogd/ready";
      # -n: foreground for finit; no -l, so it is a client only
      command =
        "${cfg.package}/bin/ntpd -n "
        + lib.escapeShellArgs (
          lib.concatMap (s: [
            "-p"
            s
          ]) cfg.servers
        );
      log = lib.mkIf syslog { };
    };

    warnings = lib.optional (
      !lib.all isIP cfg.servers
      && !config.micro.dns.dhcp
      && config.micro.dns.nameservers == [ ]
      && !config.programs.resolvconf.enable
    ) "micro.ntp.servers has host names but no name servers are configured (micro.dns)";
  };
}
