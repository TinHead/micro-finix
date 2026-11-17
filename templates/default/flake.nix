{
  description = "A board running micro-finix";

  inputs = {
    # change to wherever you get micro-finix from
    micro-finix.url = "github:TinHead/micro-finix";
    # Don't make micro-finix follow your own nixpkgs: it is pinned to
    # finix's nixpkgs, and a different pin means building another musl
    # cross toolchain from scratch.
  };

  outputs =
    { micro-finix, ... }:
    let
      buildSystem = "x86_64-linux";

      board = micro-finix.lib.microSystem {
        inherit buildSystem;
        # one of micro-finix's devices (qemu-aarch64, qemu-mipsel,
        # rpi-zerow, rpi-zero2w, dap-x1860), or your own attrset:
        # { platform = { config = "..."; }; module = ./board.nix; }
        device = micro-finix.devices.rpi-zero2w;
        modules = [ ./configuration.nix ];
      };

      inherit (board.config.system) build;
    in
    {
      # the evaluated system, for `nix eval`/`nix repl`
      legacyPackages.${buildSystem}.board = board;

      packages.${buildSystem} = {
        # disk image without secrets (use `nix run .#image` for a card)
        default = build.diskImage;
        # image-mode A/B update bundle (store image + boot files)
        update = build.updateBundle;
      };

      apps.${buildSystem} = {
        # first flash: the disk image with micro.secrets already on its
        # data partition, written outside the store. dd it to the card,
        # then delete it (it holds the secrets).
        #   nix run .#image -- my-board.img
        image = {
          type = "app";
          program = "${build.provisionImage}/bin/provision-image";
        };

        # update a running board over SSH: pushes micro.secrets, writes
        # the inactive slot, switches to it, reboots and checks that it
        # came up.
        #   nix run .#deploy -- root@<board>
        deploy = {
          type = "app";
          program = "${build.deploy}/bin/deploy";
        };
      };
    };
}
