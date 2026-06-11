#!/usr/bin/env bash
# Copy local CrossCode assets into the iOS app bundle's resource folder.
#
# Copyrighted game assets are NEVER committed. This script populates the gitignored
# app/Resources/game directory from your own legally-owned copy so XcodeGen can bundle
# it as a folder reference.
#
# Asset source resolution (first hit wins):
#   1. $CCIOS_ASSET_ROOT
#   2. tools/webkit-harness/asset-root.local   (first line = path)
#   3. default Steam macOS location
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$repo_root/app/Resources/game"
entry="node-webkit.html"

resolve_src() {
  if [[ -n "${CCIOS_ASSET_ROOT:-}" && -f "$CCIOS_ASSET_ROOT/$entry" ]]; then
    echo "$CCIOS_ASSET_ROOT"; return 0
  fi
  local local_file="$repo_root/tools/webkit-harness/asset-root.local"
  if [[ -f "$local_file" ]]; then
    local p; p="$(head -n1 "$local_file" | tr -d '\n')"
    if [[ -n "$p" && -f "$p/$entry" ]]; then echo "$p"; return 0; fi
  fi
  local steam="$HOME/Library/Application Support/Steam/steamapps/common/CrossCode/CrossCode.app/Contents/Resources/app.nw/assets"
  if [[ -f "$steam/$entry" ]]; then echo "$steam"; return 0; fi
  return 1
}

if ! src="$(resolve_src)"; then
  echo "error: could not locate CrossCode assets (expected a dir containing $entry)." >&2
  echo "Set CCIOS_ASSET_ROOT or tools/webkit-harness/asset-root.local." >&2
  exit 1
fi

echo "Syncing assets:"
echo "  from: $src"
echo "  to:   $dest"
mkdir -p "$dest"
rsync -a --delete "$src/" "$dest/"
count=$(find "$dest" -type f | wc -l | tr -d ' ')
size=$(du -sh "$dest" | cut -f1)
echo "Copied: $count files, $size."

# iOS audio fix: CrossCode ships Ogg Vorbis (.ogg), which iOS WebKit cannot decode via
# Web Audio (it raises a fatal "Web Audio Load Error"). Transcode every .ogg to .m4a
# (AAC) — natively decodable on all Apple platforms — and remove the .ogg to keep the
# bundle lean. The served game.compiled.js is patched (GameSchemeHandler.preferM4AAudio)
# to request .m4a. Set CCIOS_SKIP_TRANSCODE=1 to skip (e.g. for a macOS-only test bundle).
if [[ "${CCIOS_SKIP_TRANSCODE:-0}" == "1" ]]; then
  echo "Skipping Ogg→M4A transcode (CCIOS_SKIP_TRANSCODE=1)."
  exit 0
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "warning: ffmpeg not found — skipping Ogg→M4A transcode. Audio will crash on iOS." >&2
  echo "Install with: brew install ffmpeg" >&2
  exit 0
fi

echo "Transcoding Ogg → M4A (AAC) for iOS audio compatibility…"
ogg_total=$(find "$dest" -type f -name '*.ogg' | wc -l | tr -d ' ')
echo "  $ogg_total .ogg files to convert (parallelised)…"

export -f 2>/dev/null || true
# Convert in parallel; -vn drop video, AAC 160k stereo, faststart for streaming seek.
find "$dest" -type f -name '*.ogg' -print0 \
  | xargs -0 -P "$(sysctl -n hw.ncpu)" -I {} bash -c '
      src="$1"; out="${src%.ogg}.m4a"
      if ffmpeg -nostdin -loglevel error -y -i "$src" -vn -c:a aac -b:a 160k -movflags +faststart "$out" </dev/null; then
        rm -f "$src"
      else
        echo "transcode failed: $src" >&2
      fi
    ' _ {}

m4a_count=$(find "$dest" -type f -name '*.m4a' | wc -l | tr -d ' ')
ogg_left=$(find "$dest" -type f -name '*.ogg' | wc -l | tr -d ' ')
final_size=$(du -sh "$dest" | cut -f1)
echo "Done: $m4a_count .m4a created, $ogg_left .ogg remaining, bundle $final_size."
[[ "$ogg_left" == "0" ]] || echo "warning: $ogg_left .ogg files did not convert." >&2

