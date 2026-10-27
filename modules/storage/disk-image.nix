# Assemble the partition images into one raw disk image (MBR, 1 MiB
# aligned), checking each filesystem image fits its partition and
# growing those marked `growFilesystem` to the partition size.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  parts = lib.sort (a: b: a.index < b.index) (lib.attrValues config.micro.storage.partitions);
  bpkgs = pkgs.buildPackages;
in
{
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
}
