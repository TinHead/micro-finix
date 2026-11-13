# Name resolution. Without this, image-mode systems have no
# /etc/resolv.conf at all, so only /etc/hosts names and IP literals
# resolve.
#
# - `dhcp`: finix's resolvconf (openresolv) collects the name servers
#   the network stack hands it; iwd does so once resolvconf is enabled
#   (finix sets iwd's NameResolvingService accordingly).
# - `nameservers` alone: a static /etc/resolv.conf from the store.
# - both: the static servers are prepended to the DHCP ones.
{
  config,
  lib,
  ...
}:
let
  cfg = config.micro.dns;
in
{
  options.micro.dns = {
    dhcp = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Take name servers from DHCP, through resolvconf. With
        {option}`micro.wifi.client` iwd's built-in DHCP client supplies
        them. Adds openresolv (a shell script) and coreutils.
      '';
    };

    nameservers = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [ "192.168.1.1" ];
      description = ''
        Static name servers. Alone they make a fixed /etc/resolv.conf;
        with {option}`micro.dns.dhcp` they come before the DHCP ones.
      '';
    };

    search = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [ "lan" ];
      description = "Search domains, prepended to any DHCP ones.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.dhcp {
      programs.resolvconf.enable = true;
      programs.resolvconf.settings =
        lib.optionalAttrs (cfg.nameservers != [ ]) { name_servers = cfg.nameservers; }
        // lib.optionalAttrs (cfg.search != [ ]) { search_domains = cfg.search; };
    })

    (lib.mkIf (!cfg.dhcp && (cfg.nameservers != [ ] || cfg.search != [ ])) {
      environment.etc."resolv.conf".text =
        lib.optionalString (cfg.search != [ ]) "search ${lib.concatStringsSep " " cfg.search}\n"
        + lib.concatMapStrings (ns: "nameserver ${ns}\n") cfg.nameservers;
    })

    {
      assertions = [
        {
          assertion = cfg.dhcp || cfg.search == [ ] || cfg.nameservers != [ ];
          message = "micro.dns.search is set without micro.dns.nameservers or micro.dns.dhcp";
        }
      ];
    }
  ];
}
