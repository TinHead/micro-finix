{
  description = "micro-finix: finix (finit as pid 1, NixOS-shaped modules) built Liminix-style for small hardware";

  inputs = {
    # keep in step with finix's own pin (finix/lon.lock)
    nixpkgs.url = "github:nixos/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";
    finix.url = "github:finix-community/finix";
  };

  outputs =
    {
      self,
      nixpkgs,
      finix,
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
