# Your board. Everything finix offers works here (finit services,
# users, environment.etc, ...); micro-finix adds the micro.* options:
# micro.wifi.client, micro.ssh, micro.dns, micro.ntp, micro.update.mode,
# micro.kernel.config, micro.console. The examples/ directory of
# micro-finix has more to copy from.
#
# Secrets (Wi-Fi passphrases, passwords, tokens) don't belong in this
# file: everything here ends up in the world-readable Nix store. Declare
# them as micro.secrets files instead: a command on your machine prints
# each one when you build the card image (`nix run .#image`) or deploy
# (`nix run .#deploy`), and it lands on the data partition (/var/lib).
{ pkgs, modules, ... }:
{
  networking.hostName = "my-board";

  # console login. Generate a hash with `mkpasswd -m sha-512`; to keep
  # it out of the store too, use
  #   users.users.root.passwordFile = "/var/lib/secrets/root.hash";
  # plus a micro.secrets.files."secrets/root.hash" entry.
  services.getty.enable = true;
  users.users.root.password = "$6$microsalt$7VnpkvMQdhVomcSNHB1ItYHHLmdeoaZktYM8ENaXF6lG9ElVmTKmc0nZBdTNZ3JTVh01zqdYZ9822KLqC3t1c0"; # "micro"

  micro.wifi.client.enable = true;
  micro.dns.dhcp = true;
  micro.ntp.enable = true;

  # iwd's network file for SSID "MyNetwork". The command can be anything
  # that prints the passphrase: `pass show wifi`, `sops -d ...` (add the
  # tool to micro.secrets.packages, e.g. pkgs.buildPackages.sops), ...
  micro.secrets.files."iwd/MyNetwork.psk" = {
    command = ''cat "$HOME/.config/micro/MyNetwork.passphrase"'';
    prefix = "[Security]\nPassphrase=";
    suffix = "\n";
  };

  micro.ssh = {
    enable = true;
    rootAuthorizedKeys = [ "ssh-ed25519 REPLACE-WITH-YOUR-PUBLIC-KEY you@example" ];
  };

  # finix's service modules are opt-in imports from `modules`, e.g.
  # imports = [ modules.chronyd ];
  imports = [ ];

  # your own service: finit runs it with a minimal PATH, so use store
  # paths, and keep state under /var/lib (/ is a tmpfs in image mode)
  # finit.services.hello = {
  #   description = "hello";
  #   command = "${pkgs.busybox}/bin/httpd -f -p 80 -h /var/lib/www";
  # };
}
