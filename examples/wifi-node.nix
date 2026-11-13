# A headless board on Wi-Fi: iwd with DHCP, DNS from DHCP, NTP, and SSH
# with keys. Built for rpi-zero2w (legacyPackages.<system>.examples.
# wifi-node); any device with a radio works the same way.
#
# Wi-Fi credentials never go into the Nix store (it is world-readable
# on the device and usually pushed to a binary cache). They are a
# micro.secrets file on the persistent data partition: its command runs
# on your machine when you build the image or deploy, e.g.
#   nix build .#legacyPackages.x86_64-linux.examples.wifi-node.config.system.build.provisionImage
#   ./result/bin/provision-image wifi-node.img     # dd to the card, then delete
# Alternatively, on the console once: `iwctl station wlan0 connect <ssid>`.
# iwd connects to every network it has a file for.
{
  # console login (root / micro) from the minimal example
  imports = [ ./minimal.nix ];

  networking.hostName = "wifi-node";

  micro.wifi.client.enable = true;

  # /var/lib/iwd/<SSID>.psk, from a file outside the repository; swap the
  # command for `pass show ...`, `sops -d ...` (and add the tool to
  # micro.secrets.packages) or whatever holds your secrets
  micro.secrets.files."iwd/MyNetwork.psk" = {
    command = ''cat "$HOME/.config/micro/MyNetwork.passphrase"'';
    prefix = "[Security]\nPassphrase=";
    suffix = "\n";
  };

  # name servers from DHCP (iwd -> resolvconf); add fixed ones with
  # micro.dns.nameservers
  micro.dns.dhcp = true;

  # the boards have no RTC: the clock starts at 2000 until ntpd steps it
  micro.ntp.enable = true;

  micro.ssh = {
    enable = true;
    # placeholder: put your own public keys here
    rootAuthorizedKeys = [ "ssh-ed25519 REPLACE-WITH-YOUR-PUBLIC-KEY you@example" ];
  };
}
