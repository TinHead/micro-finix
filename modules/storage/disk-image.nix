# Assemble the partition images into one raw disk image (MBR, 1 MiB
# aligned), checking each filesystem image fits its partition.
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
        nativeBuildInputs = [ bpkgs.util-linux ];
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
            echo "${toString p.index} $off ${toString p.size} ${
              if p.image == null then "-" else p.image
            }" >> plan
            off=$((off + ${toString p.size}))
        '') parts}

        truncate -s "''${off}M" $out
        printf 'label: dos\n%s' "$layout" | sfdisk --quiet $out

        while read -r idx start size img; do
          [ "$img" = - ] && continue
          dd if="$img" of=$out bs=1M seek="$start" conv=notrunc,sparse status=none
        done < plan
      '';
}
