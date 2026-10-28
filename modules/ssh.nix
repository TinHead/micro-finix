# Opt-in SSH access: dropbear with root's authorized keys. Host keys are
# generated on first boot into dropbear's state directory (persistent
# data partition). root's home is on tmpfs in image mode, so the
# authorized keys are written from the store at every boot.
{
  config,
  pkgs,
  lib,
  modules,
  ...
}:
let
  cfg = config.micro.ssh;
  keysFile = pkgs.writeText "root-authorized-keys" (lib.concatLines cfg.rootAuthorizedKeys);
in
{
  imports = [ modules.dropbear ];

  options.micro.ssh = {
    enable = lib.mkEnableOption "SSH access via dropbear";

    rootAuthorizedKeys = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = "Public keys allowed to log in as root.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.dropbear.enable = true;

    finit.tasks.root-authorized-keys = {
      description = "install root's authorized_keys";
      runlevel = "S";
      command = pkgs.writeShellScript "root-authorized-keys" ''
        install -d -m 700 /root/.ssh
        install -m 600 ${keysFile} /root/.ssh/authorized_keys
      '';
    };

    assertions = [
      {
        assertion = cfg.rootAuthorizedKeys != [ ];
        message = "micro.ssh is enabled without any micro.ssh.rootAuthorizedKeys";
      }
    ];
  };
}
