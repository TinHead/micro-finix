{
  pkgs,
  config,
  inputs,
  ...
}:
let
  pkgs-unstable = import inputs.nixpkgs-unstable { system = pkgs.stdenv.system; };
  # crush-pkg = pkgs.callPackage ./pkgs/crush.nix { };
in
{
  packages = with pkgs; [
    sops
    age
    ssh-to-age
    pkgs-unstable.claude-code
    (rtk.overrideAttrs (old: {
      doCheck = false;
    }))
  ];
  # nixpkgs.config.allowUnfree = true;
  claude.code.enable = true;
  claude.code.mcpServers.devenv = {
    type = "stdio";
    command = "devenv";
    args = [ "mcp" ];
    env = {
      DEVENV_ROOT = config.devenv.root;
    };
  };
  claude.code.mcpServers.mcp-nixos = {
    type = "stdio";
    command = "nix";
    args = [
      "run"
      "github:utensils/mcp-nixos"
    ];
  };
}
