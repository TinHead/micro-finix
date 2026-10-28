# Minimal kernel built from an attrset of Kconfig symbols (Liminix-style).
#
# The config starts from `allnoconfig` and only what is listed here is
# switched on, so devices list their drivers explicitly. The build fails
# if Kconfig silently drops a requested symbol (unmet dependency, typo).
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.micro.kernel;

  # conditionalConfig: { USB = { USB_XHCI_HCD = "y"; }; } applies the inner
  # set only when USB is enabled
  merged = lib.foldlAttrs (
    acc: name: value:
    if (acc ? ${name}) && acc.${name} != "n" then acc // value else acc
  ) cfg.config cfg.conditionalConfig;

  kconfigLine =
    name: value: if value == "n" then "# CONFIG_${name} is not set" else "CONFIG_${name}=${value}";

  fragment = pkgs.writeText "micro-kconfig" (lib.concatLines (lib.mapAttrsToList kconfigLine merged));

  configfile = pkgs.stdenv.mkDerivation {
    pname = "micro-linux-config";
    inherit (cfg) src version;
    patches = map (p: p.patch) cfg.patches;

    depsBuildBuild = [ pkgs.buildPackages.stdenv.cc ];
    nativeBuildInputs = with pkgs.buildPackages; [
      bison
      flex
      bc
      perl
    ];

    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      make ARCH=${pkgs.stdenv.hostPlatform.linuxArch} \
        CROSS_COMPILE=${pkgs.stdenv.cc.targetPrefix} \
        HOSTCC=$CC_FOR_BUILD \
        KCONFIG_ALLCONFIG=${fragment} \
        allnoconfig
      runHook postBuild
    '';

    # not checkPhase: stdenv skips it when cross-compiling
    postBuild = ''
      lost=0
      while IFS= read -r line; do
        case "$line" in
          "# CONFIG_"*" is not set")
            sym=''${line#\# }; sym=''${sym% is not set}
            if grep -qE "^$sym=(y|m)$" .config; then
              echo "kconfig: $sym requested off but is on"; lost=1
            fi
            ;;
          CONFIG_*)
            if ! grep -qxF "$line" .config; then
              echo "kconfig: lost $line (got: $(grep -E "^(# )?''${line%%=*}[= ]" .config || echo unset))"; lost=1
            fi
            ;;
        esac
      done < ${fragment}
      if [ $lost = 1 ]; then
        echo "requested kernel options were dropped: unmet dependencies or unknown symbols"
        ${if cfg.strict then "exit 1" else "true"}
      fi
    '';

    installPhase = "cp .config $out";
  };

  # nixpkgs' kernel postInstall pipes modules.order into a bare
  # `xargs rm`; with MODULES=y but nothing =m the list is empty and rm
  # fails ("missing operand", exit 123). Add -r; the throw flags when
  # upstream changes the line so this can be dropped.
  emptyModulesRm = "| xargs -d'\\n' rm";
  fixEmptyModules =
    old:
    lib.throwIfNot (lib.hasInfix emptyModulesRm old.postInstall)
      "micro.kernel: nixpkgs kernel postInstall changed; re-check the empty modules.order workaround"
      {
        postInstall =
          builtins.replaceStrings [ emptyModulesRm ] [ "| xargs -r -d'\\n' rm" ]
            old.postInstall;
      };

  # nixpkgs installs the kernel with `make install`, relying on the arch
  # Makefile calling ~/bin/installkernel (which nixpkgs points at a script
  # copying the image and System.map to $out). MIPS' `install` target
  # doesn't: it copies vmlinux-<release> and, with SYS_SUPPORTS_ZBOOT
  # (Malta, Ralink), vmlinuz-<release>, which the build never made
  # ("cannot stat 'vmlinuz'"). Copy the image ourselves, as installkernel
  # would, and keep the remaining install targets (modules_install, ...).
  fixMipsInstall =
    old:
    lib.optionalAttrs pkgs.stdenv.hostPlatform.isMips (
      lib.throwIfNot (lib.elem "install" old.installTargets)
        "micro.kernel: nixpkgs kernel installTargets changed; re-check the MIPS install workaround"
        {
          installTargets = lib.remove "install" old.installTargets;
          preInstall = ''
            install -D -m 755 "$buildRoot/${old.passthru.target}" "$out/${old.passthru.target}"
            install -D -m 644 "$buildRoot/System.map" "$out/System.map"
          ''
          + (old.preInstall or "");
        }
    );

  kernel =
    (pkgs.linuxKernel.manualConfig {
      inherit (cfg) src version;
      inherit configfile;
      kernelPatches = cfg.patches;
      config = lib.mapAttrs' (n: v: lib.nameValuePair "CONFIG_${n}" v) (
        lib.filterAttrs (_: v: v != "n") merged
      );
    }).overrideAttrs
      (old: fixEmptyModules old // fixMipsInstall old);
in
{
  imports = [ ./base.nix ];

  options.micro.kernel = {
    enable = lib.mkEnableOption "the micro kernel builder (otherwise finix's boot.kernelPackages is used)";

    src = lib.mkOption {
      type = lib.types.path;
      default = pkgs.linux.src;
      defaultText = lib.literalExpression "pkgs.linux.src";
      description = "Kernel source tree or tarball.";
    };

    version = lib.mkOption {
      type = lib.types.str;
      default = pkgs.linux.version;
      defaultText = lib.literalExpression "pkgs.linux.version";
    };

    patches = lib.mkOption {
      type = with lib.types; listOf attrs;
      default = [ ];
      description = "Kernel patches, in nixpkgs `kernelPatches` form (`{ name; patch; }`).";
    };

    config = lib.mkOption {
      type = with lib.types; attrsOf nonEmptyStr;
      default = { };
      example = {
        TMPFS = "y";
        CMDLINE = ''"console=ttyS0"'';
      };
      description = ''
        Kconfig symbols without the `CONFIG_` prefix, applied on top of
        `allnoconfig`. String values carry their own quotes.
      '';
    };

    conditionalConfig = lib.mkOption {
      type = with lib.types; attrsOf (attrsOf nonEmptyStr);
      default = { };
      description = "Symbols applied only when the named symbol is enabled.";
    };

    strict = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Fail the build when a requested symbol does not survive Kconfig.";
    };

    configfile = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = configfile;
      description = "The generated .config (for inspection).";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelPackages = pkgs.linuxPackagesFor kernel;

    # everything the micro kernel needs is built in; finix's stock lists
    # name PC modules that do not exist here
    boot.kernelModules = lib.mkForce [ ];
    boot.initrd.kernelModules = lib.mkForce [ ];
    boot.initrd.availableKernelModules = lib.mkForce [ ];
  };
}
