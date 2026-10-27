# Smallest useful system: console login, nothing else.
{
  networking.hostName = "micro";
  services.getty.enable = true;

  # password "micro" -- examples only
  users.users.root.password = "$6$microsalt$7VnpkvMQdhVomcSNHB1ItYHHLmdeoaZktYM8ENaXF6lG9ElVmTKmc0nZBdTNZ3JTVh01zqdYZ9822KLqC3t1c0";
}
