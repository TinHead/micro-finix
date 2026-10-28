# Evaluate a micro-finix system.
#
# A device is a plain attrset (or a path to one):
#   {
#     platform = { config = "aarch64-unknown-linux-musl"; };  # nixpkgs crossSystem
#     overlays = [ ];                                          # optional
#     module = ./module.nix;                                   # hardware options
#   }
#
# The platform has to be known before the module system runs because
# it selects the package set, so it lives outside the module.
{
  nixpkgs,
  finix,
  microModules,
  # pinned non-flake sources (e.g. openwrt) devices take files from;
  # modules get them as the `microSources` argument
  sources ? { },
}:
{
  device,
  modules ? [ ],
  buildSystem ? "x86_64-linux",
  specialArgs ? { },
}:
let
  inherit (nixpkgs) lib;

  dev = if builtins.isAttrs device then device else import device;

  pkgs = import nixpkgs {
    localSystem = buildSystem;
    crossSystem = dev.platform;
    overlays = [
      finix.overlays.without-systemd
      (import ../overlays/micro.nix)
    ]
    ++ (dev.overlays or [ ]);
  };

  eval = lib.evalModules {
    class = "nixos";
    specialArgs = {
      modules = finix.nixosModules;
      microSources = sources;
    }
    // specialArgs;
    modules = [
      finix.nixosModules.default
      microModules
      dev.module
      { nixpkgs.pkgs = pkgs; }
    ]
    ++ modules;
  };
in
eval
// {
  inherit pkgs;
  inherit (eval.config.system) build;
}
