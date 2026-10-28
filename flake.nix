{
  nixConfig = {
    extra-substituters = [
      "https://cache.darker.ro/darker"
      "https://finix.cachix.org"
    ];
    extra-trusted-public-keys = [
      "darker:HE7ECkTcAxepTNmEqloGLMnfGbzOmuvSdzZBEOgx+KY="
      "finix.cachix.org-1:0ejikHDeCp0UErsduUUHcg9IJczY2/h2e5132Z/As/c="
    ];
  };

  description = "micro-finix: finix (finit as pid 1, NixOS-shaped modules) built Liminix-style for small hardware";

  inputs = {
    # keep in step with finix's own pin (finix/lon.lock)
    nixpkgs.url = "github:nixos/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";
    finix.url = "github:finix-community/finix";
    # board support (kernel drivers, device trees, image tools) that
    # isn't in mainline; devices take single files from it
    openwrt = {
      url = "github:openwrt/openwrt/e54d48c11e6e45bb662339233389c94dabc87143";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      finix,
      openwrt,
    }:
    let
      lib = nixpkgs.lib;
      buildSystems = [ "x86_64-linux" ];
      forAllSystems = lib.genAttrs buildSystems;
    in
    {
      nixosModules.default = ./modules;

      devices = import ./devices;

      lib.microSystem = import ./lib/micro-system.nix {
        inherit nixpkgs finix;
        microModules = self.nixosModules.default;
        sources = { inherit openwrt; };
      };

      # example systems, one per device, built on each build system
      legacyPackages = forAllSystems (
        buildSystem:
        lib.mapAttrs (
          name: device:
          self.lib.microSystem {
            inherit device buildSystem;
            modules = [ ./examples/minimal.nix ];
          }
        ) self.devices
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
