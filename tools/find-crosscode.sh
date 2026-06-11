#!/usr/bin/env bash
# Locate a CrossCode asset root on this Mac.
#
# A valid asset root is the directory that directly contains `node-webkit.html`
# (i.e. .../app.nw/assets). We never touch or copy anything here — we just print
# validated, de-duplicated candidate paths, one per line, so setup.sh can pick one.
#
# Resolution order (each validated against the node-webkit.html marker):
#   1. $CCIOS_ASSET_ROOT
#   2. tools/webkit-harness/asset-root.local  (first line)
#   3. Steam libraries (default + every path in libraryfolders.vdf)
#   4. GOG / standalone CrossCode.app bundles (/Applications, ~/Applications)
#   5. itch + a shallow scan of the Applications folders
#
# Usage:
#   tools/find-crosscode.sh           # print all validated candidates
#   tools/find-crosscode.sh --first   # print only the first (best) match
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
marker="node-webkit.html"
first_only=0
[[ "${1:-}" == "--first" ]] && first_only=1

# Relative path from a Steam library root to the asset directory.
steam_rel="steamapps/common/CrossCode/CrossCode.app/Contents/Resources/app.nw/assets"

# Accumulate candidates (bash 3.2 friendly: plain array, validate + dedupe at the end).
candidates=()
add() { if [[ -n "${1:-}" ]]; then candidates+=("$1"); fi; }

# 1. Explicit override -----------------------------------------------------------------
add "${CCIOS_ASSET_ROOT:-}"

# 2. Saved local config ----------------------------------------------------------------
local_file="$repo_root/tools/webkit-harness/asset-root.local"
[[ -f "$local_file" ]] && add "$(head -n1 "$local_file" | tr -d '\n')"

# 3. Steam -----------------------------------------------------------------------------
steam_root="$HOME/Library/Application Support/Steam"
add "$steam_root/$steam_rel"
vdf="$steam_root/steamapps/libraryfolders.vdf"
if [[ -f "$vdf" ]]; then
  # Extract every "path" "<dir>" value (paths may contain spaces).
  while IFS= read -r p; do
    add "$p/$steam_rel"
  done < <(grep -Eo '"path"[[:space:]]+"[^"]+"' "$vdf" | sed -E 's/^"path"[[:space:]]+"(.*)"$/\1/')
fi

# 4. GOG / standalone app bundles ------------------------------------------------------
for base in "/Applications/CrossCode.app" "$HOME/Applications/CrossCode.app"; do
  add "$base/Contents/Resources/app.nw/assets"
done

# 5. itch + shallow scan of Applications dirs ------------------------------------------
for scan in "$HOME/Library/Application Support/itch/apps" "$HOME/Applications" "/Applications"; do
  [[ -d "$scan" ]] || continue
  while IFS= read -r f; do
    add "$(dirname "$f")"
  done < <(find "$scan" -maxdepth 6 -name "$marker" 2>/dev/null)
done

# Validate (marker present) + de-duplicate, preserving order.
seen=""
printed=0
for c in "${candidates[@]:-}"; do
  [[ -n "$c" && -f "$c/$marker" ]] || continue
  # Canonicalise so the same dir reached two ways dedupes cleanly.
  abs="$(cd "$c" 2>/dev/null && pwd)" || continue
  case "$seen" in
    *"|$abs|"*) continue ;;
  esac
  seen="$seen|$abs|"
  echo "$abs"
  printed=$((printed + 1))
  [[ "$first_only" -eq 1 ]] && break
done

[[ "$printed" -gt 0 ]]
