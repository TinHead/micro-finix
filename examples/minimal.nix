# Smallest useful system: console login, nothing else. The other
# examples build on it.
{ lib, ... }:
{
  networking.hostName = lib.mkDefault "micro";
  services.getty.enable = true;

  # password "micro" -- examples only
  users.users.root.password = "$6$microsalt$7VnpkvMQdhVomcSNHB1ItYHHLmdeoaZktYM8ENaXF6lG9ElVmTKmc0nZBdTNZ3JTVh01zqdYZ9822KLqC3t1c0";
}
