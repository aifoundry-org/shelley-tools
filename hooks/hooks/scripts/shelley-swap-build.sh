#!/usr/bin/env bash
# Version-independent RELEASE builder for the hot-swap flow.
#
# Why this exists (not just `make build`): a plain build embeds the absolute
# path of ui/src into dist/build-info.json, and ui/embedfs.go's init() then
# refuses to start ("UI build is stale!") if any ui/src file is newer than the
# build. Because we build and deploy on the SAME machine, the post-build
# `git switch` back to the working branch bumps ui/src mtimes and bricks the
# deployed binary on its next restart. See /tmp/shelley-swap-analysis.md.
#
# This wrapper produces a binary with the staleness check DISABLED, and does so
# WITHOUT depending on the checked-out tree containing any special Makefile
# target — because `swap <tag>` builds arbitrary upstream tags that predate our
# source-level `build-release` target. It uses two independent mechanisms so it
# works on any tree:
#   1. exports SHELLEY_RELEASE_BUILD=1 (honored by trees that support it), and
#   2. after the UI build, forcibly rewrites dist/build-info.json's srcDir to ""
#      (works on every tree — embedfs.go skips the check when srcDir is empty).
#
# Usage: shelley-swap-build.sh <repo-dir> [output-binary-path]
#   Builds UI -> patches build-info -> templates -> go build.
#   Prints the final binary path on the last stdout line as: BUILT=<path>
set -euo pipefail

REPO="${1:?usage: shelley-swap-build.sh <repo-dir> [out]}"
OUT="${2:-$REPO/bin/shelley}"
cd "$REPO"

export SHELLEY_RELEASE_BUILD=1

echo ">> [swap-build] repo=$REPO out=$OUT"

# 1. Build the UI. Prefer the Makefile's `ui` target (version-faithful); fall
#    back to the raw pnpm invocation if that target is somehow absent.
if make -n ui >/dev/null 2>&1; then
  echo ">> [swap-build] make ui"
  make ui
else
  echo ">> [swap-build] (no 'ui' target) running pnpm build directly"
  ( cd ui && pnpm install --frozen-lockfile --silent && pnpm run --silent build )
fi

# 2. Force-disable the staleness check by blanking srcDir in the embedded
#    build-info.json. Do this REGARDLESS of what the tree's build.js did, so a
#    tag that predates SHELLEY_RELEASE_BUILD support is still made safe.
BI="ui/dist/build-info.json"
if [ ! -f "$BI" ]; then
  echo ">> [swap-build] FATAL: $BI not produced by UI build" >&2
  exit 1
fi
python3 - "$BI" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f:
    d = json.load(f)
before = d.get("srcDir", "<missing>")
d["srcDir"] = ""            # disables ui/embedfs.go staleness self-check
d["releaseBuild"] = True    # breadcrumb for anyone inspecting the binary
with open(p, "w") as f:
    json.dump(d, f, indent=2)
print(f">> [swap-build] patched build-info.json srcDir: {before!r} -> ''")
PY

# 3. Templates (tarballs embedded by the Go build), if the target exists.
if make -n templates >/dev/null 2>&1; then
  echo ">> [swap-build] make templates"
  make templates
fi

# 4. Compile the Go binary, embedding the patched dist/.
echo ">> [swap-build] go build -> $OUT"
mkdir -p "$(dirname "$OUT")"
go build -o "$OUT" ./cmd/shelley

# 5. Verify the embedded srcDir really is empty (guards against a stray rebuild
#    of the UI between steps 2 and 4).
if strings "$OUT" | grep -qE '"srcDir": *"/'; then
  echo ">> [swap-build] FATAL: built binary still embeds a non-empty srcDir; refusing." >&2
  exit 1
fi

echo ">> [swap-build] OK"
echo "BUILT=$OUT"
