# In-place A/B updates for image mode.
#
#   micro-update (on the device)   writes the inactive slot: store image
#                                  from stdin (verified by read-back),
#                                  boot files via the backend, switch
#   system.build.updateBundle      what an update ships: store squashfs
#                                  (+ size, sha256), each slot's boot files
#   system.build.deploy            `deploy <ssh-target>` from the build
#                                  machine: stream the bundle into the
#                                  inactive slot, switch, reboot, check;
#                                  micro.secrets are pushed first
#
# Active when the boot backend provides micro.boot.update (slot files
# and the switch). No automatic rollback yet: the old slot stays intact
# and switching back is `micro-update switch <old>` (or editing the
# bootloader config by hand if the new slot doesn't come up).
{
  config,
  pkgs,
  lib,
  ...
}:
let
  update = config.micro.boot.update;
  storage = config.micro.storage;
  bpkgs = pkgs.buildPackages;
  storeImage = config.system.build.storeImage;
  enabled = config.micro.update.mode == "image" && update.slotFiles != null;

  microUpdate = pkgs.writeShellScriptBin "micro-update" ''
    set -eu
    export PATH=/run/current-system/sw/bin:$PATH

    die() { echo "micro-update: $*" >&2; exit 1; }
    running=$(cat /dev/micro/slot 2>/dev/null) || die "no /dev/micro/slot (not an image-mode boot?)"
    dev_of() {
      case "$1" in
        a) echo ${storage.partitions.root-a.device} ;;
        b) echo ${storage.partitions.root-b.device} ;;
        *) die "unknown slot '$1'" ;;
      esac
    }
    inactive() {
      dev_of "$1" >/dev/null
      [ "$1" != "$running" ] || die "slot $1 is the running slot"
    }
    mount_boot() {
      mountpoint -q /boot && return
      mkdir -p /boot
      local dev=${config.fileSystems."/boot".device or "/dev/missing-boot-partition"}
      local type=${config.fileSystems."/boot".fsType or "vfat"}
      if ! mount -t "$type" "$dev" /boot; then
        echo "mount failed, attempting fsck..." >&2
        fsck.vfat -a "$dev" || true
        mount -t "$type" "$dev" /boot || die "failed to mount $dev after fsck"
      fi
    }

    cmd=''${1:-status}
    case "$cmd" in
      status)
        echo "running slot: $running"
        echo "system: $(readlink /run/current-system)"
        ;;
      write-store)
        # write-store <slot> <size> <sha256>, image on stdin
        [ $# -eq 4 ] || die "usage: write-store <slot> <size> <sha256>"
        slot=$2 size=$3 sum=$4
        inactive "$slot"
        dev=$(dev_of "$slot")
        [ "$(blockdev --getsize64 "$dev")" -ge "$size" ] || die "$size bytes don't fit $dev"
        head -c "$size" > "$dev"
        sync
        got=$(head -c "$size" "$dev" | sha256sum | cut -d' ' -f1)
        [ "$got" = "$sum" ] || die "slot $slot: checksum mismatch after write ($got)"
        echo "slot $slot: store written to $dev, verified"
        ;;
      write-boot)
        # write-boot <slot>, tar of the slot's boot files on stdin
        [ $# -eq 2 ] || die "usage: write-boot <slot>"
        slot=$2
        inactive "$slot"
        mount_boot
        src=$(mktemp -d)
        trap 'rm -rf "$src"' EXIT
        tar -x -C "$src"
        ${update.writeBoot}
        echo "slot $slot: boot files installed"
        ;;
      switch)
        # switch <slot>: boot that slot from the next boot on
        [ $# -eq 2 ] || die "usage: switch <slot>"
        slot=$2
        dev_of "$slot" >/dev/null
        mount_boot
        ${update.switch}
        echo "next boot: slot $slot"
        ;;
      *) die "usage: micro-update status|write-store|write-boot|switch" ;;
    esac
  '';

  bundle = bpkgs.runCommand "micro-update-bundle-${config.networking.hostName}" { } ''
    mkdir $out
    ln -s ${storeImage} $out/store.squashfs
    ln -s ${microUpdate}/bin/micro-update $out/micro-update
    stat -L -c %s ${storeImage} > $out/store.size
    sha256sum ${storeImage} | cut -d' ' -f1 > $out/store.sha256
    echo ${config.system.topLevel} > $out/toplevel
    ${lib.concatMapStrings (slot: ''
      ln -s ${update.slotFiles slot} $out/boot-${slot}
    '') config.micro.boot.slots}
  '';

  deploy = bpkgs.writeShellApplication {
    name = "deploy";
    runtimeInputs = [
      bpkgs.openssh
      bpkgs.gnutar
    ];
    text = ''
      target=''${1:?usage: deploy <ssh-target> (e.g. root@192.0.2.10)}
      bundle=${bundle}
      ${lib.optionalString (config.micro.secrets.files != { }) ''
        # micro.secrets first: they may change without the system changing
        ${config.system.build.pushSecrets}/bin/push-secrets "$target"
      ''}
      ctl=$(mktemp -d)
      trap 'ssh -o ControlPath="$ctl/cm" -O exit "$target" 2>/dev/null || true; rm -rf "$ctl"' EXIT
      # one connection (one key touch) per boot, reused by every step
      remote() {
        ssh -o ControlMaster=auto -o ControlPath="$ctl/cm" -o ControlPersist=120 \
          -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
          "$target" "$@"
      }

      # the bundle's own micro-update runs on the device (bash ignores its
      # store shebang), so the first deploy onto an older image works too
      remote 'cat > /tmp/micro-update' < "$bundle/micro-update"
      mu() { remote bash /tmp/micro-update "$@"; }

      new_system=$(cat "$bundle/toplevel")
      if [ "$(remote readlink /run/current-system)" = "$new_system" ]; then
        echo "$target already runs $new_system"
        exit 0
      fi
      running=$(remote cat /dev/micro/slot)
      case "$running" in a) slot=b ;; b) slot=a ;; *) echo "unexpected slot '$running'" >&2; exit 1 ;; esac
      echo "running slot $running; installing $new_system into slot $slot"

      mu write-store "$slot" "$(cat "$bundle/store.size")" "$(cat "$bundle/store.sha256")" \
        < "$bundle/store.squashfs"
      tar -C "$bundle/boot-$slot" -ch . | mu write-boot "$slot"
      mu switch "$slot"

      echo "rebooting into slot $slot"
      # detached and delayed, so this ssh returns before the board goes
      # down; a plain `reboot` leaves the connection half-open (dropbear
      # dies without closing it) and the client hangs until TCP gives up
      remote 'nohup sh -c "sleep 2; reboot" >/dev/null 2>&1 </dev/null &' || true
      ssh -o ControlPath="$ctl/cm" -O exit "$target" 2>/dev/null || true

      sleep 15
      for _ in $(seq 1 36); do
        if now=$(remote cat /dev/micro/slot 2>/dev/null); then
          if [ "$now" = "$slot" ] && [ "$(remote readlink /run/current-system)" = "$new_system" ]; then
            echo "$target is up on slot $slot"
            exit 0
          fi
          echo "$target came back on slot $now, not $slot (store fallback?)" >&2
          exit 1
        fi
        sleep 5
      done
      echo "$target did not come back within 3 minutes; slot $running is intact" >&2
      exit 1
    '';
  };
in
{
  config = lib.mkIf enabled {
    environment.systemPackages = [ microUpdate ];
    system.build.updateBundle = bundle;
    system.build.deploy = deploy;
  };
}
