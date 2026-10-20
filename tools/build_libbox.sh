#!/usr/bin/env bash
# Rebuild Vendor/Libbox.xcframework (sing-box core for the CainExt packet-tunnel extension).
#
#     tools/build_libbox.sh            # iOS device + iOS simulator slices
#
# Pinned to the sing-box tag below. Uses sing-box's own build_libbox tool, so the
# build tags match the official sing-box-for-apple app (including with_tailscale).
# Needs: go (brew install go), git, Xcode command-line tools.
set -euo pipefail

SING_BOX_TAG="v1.14.3"
SRC="${SING_BOX_SRC:-$HOME/projects/sing-box-src}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/Vendor/Libbox.xcframework"
LOG="$REPO_ROOT/build/libbox-build.log"

mkdir -p "$REPO_ROOT/build" "$REPO_ROOT/Vendor"

if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$SING_BOX_TAG" https://github.com/SagerNet/sing-box.git "$SRC"
fi
cd "$SRC"
current="$(git describe --tags --exact-match 2>/dev/null || true)"
if [ "$current" != "$SING_BOX_TAG" ]; then
  git fetch --depth 1 origin tag "$SING_BOX_TAG"
  git checkout -q "$SING_BOX_TAG"
fi

# gomobile fork pinned by sing-box's Makefile (lib_install target).
make lib_install >"$REPO_ROOT/build/gomobile-install.log" 2>&1
export PATH="$(go env GOPATH)/bin:$PATH"

# build_libbox moves its output into ../sing-box-for-apple when that dir exists;
# we take it from the source dir, so keep that sibling absent (clone it elsewhere).
if [ -d "$SRC/../sing-box-for-apple" ]; then
  echo "error: $SRC/../sing-box-for-apple exists and would capture the output" >&2
  exit 1
fi

echo "building Libbox ($SING_BOX_TAG) → $LOG"
go run ./cmd/internal/build_libbox -target apple -platform ios,iossimulator >"$LOG" 2>&1 || {
  tail -20 "$LOG"; exit 1; }

rm -rf "$OUT"
mv Libbox.xcframework "$OUT"
echo "ok: $OUT"
