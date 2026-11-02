# Cross rustc for ARMv6 musl: its std doesn't build. compiler_builtins'
# unaligned-access helpers (arm.rs, naked functions) return with
# `bx lr`; naked functions become module-level asm, which LLVM < 23
# parses for the bare triple's default CPU, and the plain `arm-` triple
# means ARMv4 (no `bx`): "invalid instruction ... requires: armv4t".
# rustc attaches the target features to module asm only with LLVM >= 23
# (rust-lang/rust#160594), and nixpkgs builds rustc against LLVM 21.
# With fastCross, std is compiled by the native rustc, so the fix goes
# into the library source: emit `bx lr` as its ARM encoding, which the
# assembler takes on any CPU. Only this target's std uses arm.rs (the
# thumb1 branches, also rewritten, never build for it). Drop this once
# nixpkgs' rustc uses LLVM >= 23; --replace-fail flags a source change.
final: prev:
let
  target = prev.stdenv.targetPlatform;
  armRs = "library/compiler-builtins/compiler-builtins/src/arm.rs";
in
prev.lib.optionalAttrs
  (target.config == "armv6l-unknown-linux-musleabihf" && prev.stdenv.hostPlatform != target)
  {
    rust_1_99 = prev.rust_1_99 // {
      packages = prev.rust_1_99.packages // {
        stable = prev.rust_1_99.packages.stable.overrideScope (
          _: sp: {
            rustc-unwrapped = sp.rustc-unwrapped.overrideAttrs (old: {
              postPatch = (old.postPatch or "") + ''
                substituteInPlace ${armRs} \
                  --replace-fail '"bx lr",' '".inst 0xe12fff1e", // bx lr'
              '';
            });
          }
        );
      };
    };
  }
