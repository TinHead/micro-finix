# Running your own service: a status page served by busybox httpd, with
# a CGI script and a visit counter kept on the persistent data partition.
# Built for qemu-aarch64 (legacyPackages.<system>.examples.service), so
# it boots in QEMU:
#
#   nix build .#legacyPackages.x86_64-linux.examples.service.config.system.build.runner
#   ./result/bin/run-micro-vm a
#   # log in as root / micro, then: wget -qO- http://127.0.0.1/cgi-bin/status
#
# Things finit services have to get right on micro-finix:
#   - finit starts them with a minimal PATH: use absolute store paths
#     (or bash builtins) in commands and scripts; a missing command
#     shows up only as "exit status 127".
#   - `/` is a tmpfs in image mode; only /var/lib (the data partition)
#     survives a reboot or an update.
#   - finit restarts a service that exits, up to 10 times, then marks it
#     crashed.
{
  pkgs,
  ...
}:
let
  bb = "${pkgs.busybox}/bin";
  stateDir = "/var/lib/status-page";

  # busybox httpd runs CGI scripts with the store shebang below and its
  # own minimal environment
  status = pkgs.writeShellScript "status" ''
    n=0
    [ -s ${stateDir}/visits ] && n=$(<${stateDir}/visits)
    n=$((n + 1))
    echo "$n" > ${stateDir}/visits

    echo "Content-Type: text/plain"
    echo
    echo "host:    $(<"/proc/sys/kernel/hostname")"
    echo "kernel:  $(<"/proc/sys/kernel/osrelease")"
    read -r up _ < /proc/uptime
    echo "uptime:  ''${up%.*} s"
    read -r l1 l5 l15 _ < /proc/loadavg
    echo "load:    $l1 $l5 $l15"
    echo "system:  $(${bb}/readlink /run/current-system)"
    echo "visits:  $n (kept in ${stateDir})"
  '';

  docroot = pkgs.runCommand "status-page-www" { } ''
    mkdir -p $out/cgi-bin
    ln -s ${status} $out/cgi-bin/status
    cat > $out/index.html <<'EOF'
    <!doctype html>
    <title>micro-finix</title>
    <p>See <a href="/cgi-bin/status">/cgi-bin/status</a>.</p>
    EOF
  '';
in
{
  imports = [ ./minimal.nix ];

  networking.hostName = "service-demo";

  # one-shot at boot: make the state directory on the data partition
  finit.tasks.status-page-state = {
    description = "status page state directory";
    command = "${bb}/mkdir -p ${stateDir}";
  };

  finit.services.status-page = {
    description = "status page (busybox httpd)";
    conditions = "task/status-page-state/success";
    # -f: stay in the foreground, finit supervises it
    command = "${bb}/httpd -f -p 80 -h ${docroot}";
  };
}
