# Package-level trims for small targets. Applied to every micro-finix
# package set; nothing here changes behaviour on the device, it only
# drops build- and run-time weight.
final: prev: {
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

  # fuse2fs only
  e2fsprogs = prev.e2fsprogs.override { withFuse = false; };
}
