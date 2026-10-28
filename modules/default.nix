# `modules` is finix's module set (specialArg); service modules there are
# opt-in imports. getty is pulled in so devices can name their console;
# wifi.nix and ssh.nix import theirs (options only until enabled).
{ modules, ... }:
{
  imports = [
    modules.getty
    ./boot
    ./kernel
    ./micro-update.nix
    ./profile.nix
    ./ssh.nix
    ./storage
    ./update.nix
    ./wifi.nix
  ];
}
