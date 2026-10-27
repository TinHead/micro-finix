# Defaults for small systems. Everything is mkDefault so a config can
# opt back in.
{ config, lib, ... }:
let
  cfg = config.micro;
in
{
  options.micro.console = lib.mkOption {
    type = with lib.types; nullOr str;
    default = null;
    example = "ttyAMA0";
    description = "Serial console device; gets the kernel console and a getty.";
  };

  config = lib.mkMerge [
    { services.mdevd.enable = lib.mkDefault true; }
    (lib.mkIf (cfg.console != null) {
      boot.kernelParams = [ "console=${cfg.console},115200" ];
      services.getty.ttys = lib.mkDefault [ cfg.console ];
    })
  ];
}
