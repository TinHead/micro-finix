# Closure mode instead of A/B images: a writable ext4 root that holds
# /nix/store, updated like NixOS (copy the new closure, activate it).
# Suits boards with plenty of storage where you'd rather `nix copy`
# small changes than ship a whole store image; image mode (the default)
# suits flash with an atomic A/B switch. Built for qemu-aarch64:
#
#   nix build .#legacyPackages.x86_64-linux.examples.closure-mode.config.system.build.runner
#   ./result/bin/run-micro-vm      # one root partition, so no slot argument
#
# Disk: boot (if the device has a boot partition) | root | data. Both /
# and /var/lib survive a reboot; the root filesystem is grown to its
# partition when the image is built.
{
  imports = [ ./minimal.nix ];

  networking.hostName = "closure-demo";

  micro.update.mode = "closure";
}
