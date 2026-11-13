#!/usr/bin/env bash
# realise-build-closure <drv-paths file> <out file>
#
# Writes to <out file> every output of the build closure of the given
# derivations that cache.nixos.org doesn't serve (musl cross toolchains,
# kernels, cross-built packages, the images themselves), after making
# sure each one is in the local store: substituted from a cache that has
# it, built otherwise.
#
# Why: a CI build substitutes finished outputs (images, systems) when a
# cache already has them, so Nix never fetches the compilers behind them;
# `nix-store -qR --include-outputs` then lists only what happens to be
# valid locally, and the toolchains never reach the caches. Once a
# toolchain is missing from every cache, the next change rebuilds it
# from scratch.
set -euo pipefail

drvs=${1:?usage: realise-build-closure <drv-paths file> <out file>}
out=${2:?usage: realise-build-closure <drv-paths file> <out file>}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# "<drv> <output path>" for every non-fixed-output derivation in the
# closure (fixed-output ones are source downloads). Newer Nix prints
# store paths without the /nix/store/ prefix; add it back.
# shellcheck disable=SC2046
nix derivation show -r $(cat "$drvs") \
  | jq -r '(.derivations // .) | to_entries[]
      | select([.value.outputs[] | (.hash // .outputHash // null)] | all(. == null))
      | .key as $d | .value.outputs[] | select(.path != null) | "\($d) \(.path)"' \
  | sed -E 's#(^| )([a-z0-9]{32}-)#\1/nix/store/\2#g' > "$work/drv-outputs"

cut -d' ' -f2 "$work/drv-outputs" | sort -u > "$work/outputs"

# which of them cache.nixos.org serves (the inner sh expands $c)
# shellcheck disable=SC2016
sed -E 's#^/nix/store/([a-z0-9]{32})-.*#\1#' "$work/outputs" \
  | xargs -P 32 -I{} sh -c \
    'c=$(curl -s -o /dev/null -w "%{http_code}" https://cache.nixos.org/{}.narinfo); [ "$c" = 200 ] && echo {}' \
  | sort -u > "$work/upstream-hashes" || true
grep -v -F -f "$work/upstream-hashes" "$work/outputs" > "$work/ours" || true

# realise the derivations behind missing outputs: all outputs of each
# (`^*`), so a derivation is substituted or built once, not per output
xargs nix-store --check-validity --print-invalid < "$work/ours" > "$work/invalid"
echo "build closure: $(wc -l < "$work/outputs") outputs, $(wc -l < "$work/upstream-hashes") on cache.nixos.org," \
  "$(wc -l < "$work/ours") ours, $(wc -l < "$work/invalid") not in the local store"
if [ -s "$work/invalid" ]; then
  awk 'NR==FNR { want[$1] = 1; next } ($2 in want) { print $1 "^*" }' \
    "$work/invalid" "$work/drv-outputs" | sort -u > "$work/to-realise"
  echo "realising $(wc -l < "$work/to-realise") derivations"
  if [ -n "${DRY_RUN:-}" ]; then
    xargs nix build --dry-run --no-link < "$work/to-realise" 2>&1 | grep -v '^  /nix/store/' || true
    xargs nix build --dry-run --no-link < "$work/to-realise" 2>&1 \
      | awk '/will be built/ { b = 1; f = 0; next } /will be fetched/ { f = 1; b = 0; next }
             b && /^  \/nix\/store/ { sub(/^  \/nix\/store\/[a-z0-9]*-/, "  build: "); print }' | head -40
    exit 0
  fi
  # --keep-going: one failure shouldn't stop the rest from being cached
  xargs nix build --no-link --keep-going --print-build-logs < "$work/to-realise" || true
fi

# whatever is valid now
xargs nix-store --check-validity --print-invalid < "$work/ours" > "$work/invalid"
grep -v -x -F -f "$work/invalid" "$work/ours" > "$out" || true
echo "$(wc -l < "$out") outputs to push, $(wc -l < "$work/invalid") still missing"
if [ -s "$work/invalid" ]; then
  sed 's#^/nix/store/[a-z0-9]*-#  missing: #' "$work/invalid" | head -20
fi
