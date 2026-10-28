# Block-device layout: SD card, eMMC, virtio disk. One MBR-partitioned
# raw disk image (1 MiB aligned); partitions are /dev/<dev><n> or
# /dev/<dev>p<n>; the data partition is ext4. Carries both update modes.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.micro.storage;
  bpkgs = pkgs.buildPackages;
  parts = lib.sort (a: b: a.index < b.index) (lib.attrValues cfg.partitions);
in
{
  config = lib.mkIf (cfg.layout == "block") {
    micro.storage = {
      supportedUpdateModes = [
        "image"
        "closure"
      ];

      # /dev/vda -> /dev/vda2, /dev/mmcblk0 -> /dev/mmcblk0p2
      devicePath =
        { index, ... }:
        let
          last = lib.substring (lib.stringLength cfg.device - 1) 1 cfg.device;
          sep = if builtins.match "[0-9]" last != null then "p" else "";
        in
        "${cfg.device}${sep}${toString index}";

      dataFsType = lib.mkDefault "ext4";

      partitions.data.image = lib.mkDefault (
        bpkgs.runCommand "micro-data.img" { nativeBuildInputs = [ bpkgs.e2fsprogs ]; } ''
          truncate -s ${toString cfg.dataSize}M $out
          mkfs.ext4 -q -F -L micro-data $out
        ''
      );
    };

    assertions = [
      {
        assertion = lib.length parts <= 4;
        message = "micro.storage (block): MBR allows at most 4 primary partitions";
      }
    ];

    # Assemble the partition images into one raw disk image, checking
    # each image fits its partition and growing those marked
    # `growFilesystem` to the partition size.
    system.build.diskImage =
      bpkgs.runCommand "micro-disk.img"
        {
          nativeBuildInputs = [
            bpkgs.util-linux
          ]
          ++ lib.optional (lib.any (p: p.growFilesystem && p.image != null) parts) bpkgs.e2fsprogs;
        }
        ''
          set -eu
          off=1
          layout=""
          ${lib.concatMapStrings (p: ''
              ${lib.optionalString (p.image != null) ''
                have=$(stat -L -c %s ${p.image})
                if [ "$have" -gt $((${toString p.size} * 1048576)) ]; then
                  echo "partition ${toString p.index}: image is $have bytes, partition is ${toString p.size} MiB" >&2
                  exit 1
                fi
              ''}
              layout="$layout''${off}MiB,${toString p.size}MiB,${p.type}
            "
              echo "${toString p.index} $off ${toString p.size} ${if p.image == null then "-" else p.image} ${
                if p.growFilesystem then "grow" else "-"
              }" >> plan
              off=$((off + ${toString p.size}))
          '') parts}

          truncate -s "''${off}M" $out
          printf 'label: dos\n%s' "$layout" | sfdisk --quiet $out

          while read -r idx start size img grow; do
            [ "$img" = - ] && continue
            if [ "$grow" = grow ]; then
              # resize a sparse copy; the store image stays untouched
              cp --sparse=always "$img" part.img
              chmod u+w part.img
              resize2fs -f part.img "''${size}M"
              img=part.img
            fi
            dd if="$img" of=$out bs=1M seek="$start" conv=notrunc,sparse status=none
            rm -f part.img
          done < plan
        '';
  };
}
