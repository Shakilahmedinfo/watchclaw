#!/usr/bin/env bash
# Build a clean release folder for ClawHub / distribution
set -euo pipefail

VERSION="${1:-1.0.0}"
SRC="$(cd "$(dirname "$0")" && pwd)"
OUT="$SRC/dist/watchclaw"

rm -rf "$OUT"
mkdir -p "$OUT"

cp "$SRC/watchclaw"              "$OUT/"
cp "$SRC/watchclaw.sh"           "$OUT/"
cp "$SRC/watchclaw.conf.example" "$OUT/"
cp "$SRC/SKILL.md"               "$OUT/"
cp "$SRC/README.md"              "$OUT/"
cp "$SRC/LICENSE"                 "$OUT/"

echo "✅ Release folder ready: $OUT"
echo "   Files: $(ls "$OUT" | wc -l | tr -d ' ')"
echo "   Size:  $(du -sh "$OUT" | cut -f1)"
echo ""
echo "Upload '$OUT' to ClawHub or zip it with:"
echo "   cd $SRC/dist && tar czf watchclaw-${VERSION}.tar.gz watchclaw/"
