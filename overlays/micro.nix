# Package-level trims for small targets. Applied to every micro-finix
# package set; nothing here changes behaviour on the device, it only
# drops build- and run-time weight.
#
# The overlay also applies to buildPackages (the build machine's own
# set). Trims of packages the native stdenv bootstrap uses (xz,
# findutils, ...) must be gated on `cross`, or they rebuild the whole
# native toolchain.
final: prev:
let
  cross = prev.stdenv.buildPlatform != prev.stdenv.hostPlatform;
  onTarget = trimmed: untouched: if cross then trimmed else untouched;
in
{
  # Go is only for libcap's optional Go bindings; PAM pulls audit + db
  libcap = prev.libcap.override {
    withGo = false;
    usePam = false;
  };

  # shadow's own login/passwd work against /etc/shadow without PAM
  shadow = prev.shadow.override { pam = null; };

  util-linux = prev.util-linux.override {
    pamSupport = false;
    withLastlog = false;
    nlsSupport = false;
    translateManpages = false;
  };

  # withFuse: fuse2fs only. On the target also: libarchive only serves
  # `mke2fs -d <tarball>` and drags in openssl, libxml2 (~10.5 MiB, also
  # in the initrd); NLS is 3.6 MiB of translations
  e2fsprogs =
    let
      base = prev.e2fsprogs.override { withFuse = false; };
    in
    onTarget (base.overrideAttrs (old: {
      buildInputs = final.lib.filter (p: (p.pname or "") != "libarchive") old.buildInputs;
      configureFlags =
        map (f: if f == "--with-libarchive=direct" then "--without-libarchive" else f) old.configureFlags
        ++ [ "--disable-nls" ];
    })) base;

  # One util-linux on the target: nixpkgs' util-linuxMinimal (libuuid for
  # e2fsprogs & co., `logger` in finix's switch-to-configuration) was a
  # second full copy (~14.6 MiB) next to the system util-linux.
  util-linuxMinimal = onTarget final.util-linux prev.util-linuxMinimal;

  # translations only (findutils 1.8 MiB, xz 0.9 MiB)
  findutils = onTarget (prev.findutils.overrideAttrs (old: {
    configureFlags = (old.configureFlags or [ ]) ++ [ "--disable-nls" ];
  })) prev.findutils;
  xz = onTarget (prev.xz.overrideAttrs (old: {
    configureFlags = (old.configureFlags or [ ]) ++ [ "--disable-nls" ];
  })) prev.xz;

  # unixtools.<cmd> wrappers link one binary plus its man pages, which
  # pulls the provider's whole -man output into the closure (finit ->
  # sysctl-procps -> procps-man, finix-setup -> fsck-util-linux ->
  # util-linux-man). Link the binary only.
  unixtools = onTarget (final.lib.mapAttrs (
    cmd: drv:
    if final.lib.isDerivation drv && drv ? provider then
      final.runCommand drv.name {
        inherit (drv) meta version pname;
        passthru = drv.passthru or { };
        preferLocalBuild = true;
      } "mkdir -p $out/bin; ln -s ${final.lib.getBin drv.provider}/bin/${cmd} $out/bin/${cmd}"
    else
      drv
  ) prev.unixtools) prev.unixtools;

  # skaware builds hard-code a bare `pkg-config` (configure's
  # --with-pkgconfig, execline's postInstall), but in a cross stdenv
  # only the target-prefixed wrapper is on PATH. Shim the bare name.
  skawarePackages = prev.skawarePackages.overrideScope (
    sfinal: sprev: {
      buildPackage =
        args:
        (sprev.buildPackage args).overrideAttrs (
          old:
          final.lib.optionalAttrs (final.stdenv.buildPlatform != final.stdenv.hostPlatform) {
            preConfigure = ''
              mkdir -p "$NIX_BUILD_TOP/.pkg-config-shim"
              ln -s "$(command -v "$PKG_CONFIG")" "$NIX_BUILD_TOP/.pkg-config-shim/pkg-config"
              export PATH="$NIX_BUILD_TOP/.pkg-config-shim:$PATH"
            ''
            + (old.preConfigure or "");
          }
        );
    }
  );
}
