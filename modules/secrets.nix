# Secrets on the data partition. Anything in the system configuration
# ends up in the Nix store, which is world-readable on the device and
# usually pushed to a binary cache, so secrets (Wi-Fi passphrases,
# password hashes, tokens) live as files under /var/lib instead. Updates
# never touch that partition.
#
# Each file is declared with a shell command that prints its content.
# The command runs on the machine that builds the image or deploys,
# never on the device and never in a Nix build, so it can use whatever
# keeps your secrets there: sops, age, pass, a plain file.
#
#   micro.secrets.packages = [ pkgs.buildPackages.sops ];
#   micro.secrets.files."iwd/Home.psk" = {
#     command = "sops -d --extract '[\"wifi\"]' ${./secrets.yaml}";
#     prefix = "[Security]\nPassphrase=";
#     suffix = "\n";
#   };
#
# Build outputs (scripts for the build machine):
#   system.build.renderSecrets   render-secrets <dir>: write the files to <dir>
#   system.build.pushSecrets     push-secrets <ssh-target>: write them on a
#                                running device
#   system.build.provisionImage  provision-image <file.img>: the disk image
#                                with the files already on its data
#                                partition (block layout), for first flash
# system.build.deploy (image-mode updates) pushes them before updating.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.micro.secrets;
  bpkgs = pkgs.buildPackages;
  dataDir = config.micro.update.dataMountPoint;
  storage = config.micro.storage;

  files = lib.attrValues cfg.files;
  paths = map (f: f.path) files;
  q = lib.escapeShellArg;

  # parent directories of every file, shallowest first: "a/b/c" -> a, a/b
  parentDirs = lib.unique (
    lib.concatMap (
      p:
      let
        parts = lib.init (lib.splitString "/" p);
      in
      lib.genList (i: lib.concatStringsSep "/" (lib.take (i + 1) parts)) (lib.length parts)
    ) paths
  );

  # the commands are arbitrary user shell; check syntax only
  syntaxCheck = ''
    runHook preCheck
    ${bpkgs.stdenv.shellDryRun} "$target"
    runHook postCheck
  '';

  renderSecrets = bpkgs.writeShellApplication {
    name = "render-secrets";
    runtimeInputs = cfg.packages;
    checkPhase = syntaxCheck;
    text = ''
      dir=''${1:?usage: render-secrets <dir>}
      umask 077
      mkdir -p "$dir"
      ${lib.concatMapStrings (f: ''
        mkdir -p "$dir"/${q (dirOf f.path)}
        {
          printf '%s' ${q f.prefix}
          (
        ${f.command}
          )
          printf '%s' ${q f.suffix}
        } > "$dir"/${q f.path}
        chmod ${f.mode} "$dir"/${q f.path}
      '') files}
    '';
  };

  # run on the device as root: busybox tar keeps the archived modes; -o
  # leaves the files to root, then each gets its declared owner
  remoteInstall = lib.concatStringsSep " && " (
    [
      "umask 022"
      "mkdir -p ${q dataDir}"
      "cd ${q dataDir}"
      "tar -x -o -f -"
    ]
    ++ map (f: "chown ${toString f.uid}:${toString f.gid} ${q f.path}") files
    ++ map (f: "chmod ${f.mode} ${q f.path}") files
  );

  pushSecrets = bpkgs.writeShellApplication {
    name = "push-secrets";
    runtimeInputs = [
      bpkgs.openssh
      bpkgs.gnutar
    ];
    text =
      if files == [ ] then
        ''
          : "''${1:?usage: push-secrets <ssh-target>}"
          echo "no micro.secrets declared"
        ''
      else
        ''
          target=''${1:?usage: push-secrets <ssh-target> [ssh options]}
          shift
          work=$(mktemp -d -p "''${XDG_RUNTIME_DIR:-/tmp}")
          trap 'rm -rf "$work"' EXIT
          ${renderSecrets}/bin/render-secrets "$work"
          # files only: parent directories that already exist on the device
          # keep their owner and mode
          tar -C "$work" --owner=0 --group=0 --numeric-owner -cf - -- ${lib.escapeShellArgs paths} \
            | ssh -o ConnectTimeout=10 "$@" "$target" ${q remoteInstall}
          ${lib.concatMapStrings (p: ''
            echo "secret ${dataDir}/${p}"
          '') paths}
        '';
  };

  octal = m: lib.substring (lib.stringLength m - 3) 3 m;

  # debugfs edits the data partition's ext4 image in place (no mount);
  # paths are double-quoted (iwd names network files after the SSID)
  debugfsCommands = lib.concatStrings (
    map (d: ''
      mkdir "/${d}"
      sif "/${d}" mode 040755
    '') parentDirs
    ++ map (f: ''
      write "@work@/secrets/${f.path}" "/${f.path}"
      sif "/${f.path}" mode 0100${octal f.mode}
      sif "/${f.path}" uid ${toString f.uid}
      sif "/${f.path}" gid ${toString f.gid}
    '') files
  );

  provisionImage = bpkgs.writeShellApplication {
    name = "provision-image";
    runtimeInputs = with bpkgs; [
      coreutils
      e2fsprogs
      jq
      util-linux
    ];
    text = ''
      img=''${1:?usage: provision-image <file.img>}
      install -m 600 ${config.system.build.diskImage} "$img"
      work=$(mktemp -d -p "''${XDG_RUNTIME_DIR:-/tmp}")
      trap 'rm -rf "$work"' EXIT
      ${renderSecrets}/bin/render-secrets "$work/secrets"

      # the data partition, out and back by sector offset
      read -r start size < <(sfdisk -J "$img" \
        | jq -r '.partitiontable.partitions[${
          toString (storage.partitions.data.index - 1)
        }] | "\(.start) \(.size)"')
      dd if="$img" of="$work/data.img" bs=512 skip="$start" count="$size" status=none
      cmds=${bpkgs.writeText "provision-debugfs" debugfsCommands}
      sed "s|@work@|$work|g" "$cmds" > "$work/cmds"
      debugfs -w -f "$work/cmds" "$work/data.img" > "$work/debugfs.log" 2>&1
      e2fsck -fn "$work/data.img" > "$work/fsck.log" 2>&1 \
        || { echo "provision-image: e2fsck failed on the data partition:" >&2; cat "$work/fsck.log" >&2; exit 1; }
      ${lib.concatMapStrings (f: ''
        debugfs -R ${q "stat \"/${f.path}\""} "$work/data.img" 2>/dev/null | grep -q '^Inode:' \
          || { echo "provision-image: /${f.path} missing after debugfs:" >&2; cat "$work/debugfs.log" >&2; exit 1; }
      '') files}
      dd if="$work/data.img" of="$img" bs=512 seek="$start" conv=notrunc status=none

      echo "$img: $(du -h --apparent-size "$img" | cut -f1)${
        lib.optionalString (files != [ ]) ", secrets:"
      }"
      ${lib.concatMapStrings (p: ''
        echo "  ${dataDir}/${p}"
      '') paths}
      ${lib.optionalString (files != [ ]) ''
        echo "it holds secrets: delete it once it is on the card"
      ''}
    '';
  };
in
{
  options.micro.secrets = {
    files = lib.mkOption {
      default = { };
      description = ''
        Files on the data partition (relative to
        {option}`micro.update.dataMountPoint`), produced at image or
        deploy time by a command on the deploying machine. Their content
        never enters the Nix store.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              path = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "Path relative to the data partition's mount point.";
              };
              command = lib.mkOption {
                type = lib.types.lines;
                example = "pass show wifi/home";
                description = ''
                  Shell code whose standard output is the file's content.
                  Runs on the deploying machine with
                  {option}`micro.secrets.packages` on PATH; a failure
                  aborts the image or deploy.
                '';
              };
              prefix = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "Text written before the command's output.";
              };
              suffix = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "Text written after the command's output.";
              };
              mode = lib.mkOption {
                type = lib.types.strMatching "0?[0-7]{3}";
                default = "0600";
              };
              uid = lib.mkOption {
                type = lib.types.ints.unsigned;
                default = 0;
                description = "Numeric owner (on the device).";
              };
              gid = lib.mkOption {
                type = lib.types.ints.unsigned;
                default = 0;
              };
            };
          }
        )
      );
    };

    packages = lib.mkOption {
      type = with lib.types; listOf package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.buildPackages.sops ]";
      description = ''
        Tools the commands need, for the deploying machine
        (`pkgs.buildPackages`, not the device's `pkgs`).
      '';
    };
  };

  config = {
    system.build = {
      inherit renderSecrets pushSecrets;
      provisionImage = lib.mkIf (storage.layout == "block") provisionImage;
    };

    assertions = map (p: {
      assertion = !lib.hasPrefix "/" p && !lib.elem ".." (lib.splitString "/" p) && p != "";
      message = "micro.secrets: '${p}' must be a relative path inside the data partition";
    }) paths;
  };
}
