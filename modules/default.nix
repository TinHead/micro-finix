# `modules` is finix's module set (specialArg); service modules there are
# opt-in imports. getty is pulled in so devices can name their console.
{ modules, ... }:
{
  imports = [
    modules.getty
    ./boot
    ./kernel
    ./profile.nix
    ./storage
    ./update.nix
  ];
}
