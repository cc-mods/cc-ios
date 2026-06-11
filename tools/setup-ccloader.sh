#!/usr/bin/env bash
# Overlay CCLoader (+ mods) onto the bundled game so the iOS app loads mods.
#
# Run AFTER tools/sync-assets.sh. It restructures app/Resources/game into the CCLoader
# layout and downloads CCLoader if needed:
#
#   app/Resources/game/
#     ccloader/index.html      <- entry (app auto-detects this and boots through it)
#     mods.json                <- explicit mod list (browser mode can't enumerate folders)
#     assets/                  <- the actual game (node-webkit.html, media, js, …)
#       mods/<modname>/...      <- installed mods
#
# The app's GameWebHost.resolveEntryPath() auto-detects ccloader/index.html and boots it.
#
# Usage:
#   tools/setup-ccloader.sh                      # download CCLoader, set up layout
#   tools/setup-ccloader.sh --add-mod /path/to/mod-dir-or.ccmod
#   tools/setup-ccloader.sh --ccloader /path/to/CCLoader   # use a local CCLoader copy
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
game="$repo_root/app/Resources/game"
ccloader_src=""
add_mods=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ccloader) ccloader_src="$2"; shift 2;;
    --add-mod)  add_mods+=("$2"); shift 2;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

if [[ ! -d "$game" ]]; then
  echo "error: $game not found. Run tools/sync-assets.sh first." >&2
  exit 1
fi

# --- 1. Restructure: move the game under assets/ if it's currently at the root ----------
if [[ -f "$game/node-webkit.html" && ! -f "$game/assets/node-webkit.html" ]]; then
  echo "Restructuring game under assets/ for CCLoader…"
  tmp="$(mktemp -d "$repo_root/app/Resources/.ccsetup.XXXXXX")"
  # Move everything currently in game/ into tmp/assets/
  mkdir -p "$tmp/assets"
  shopt -s dotglob
  for entry in "$game"/*; do
    [[ "$(basename "$entry")" == "ccloader" || "$(basename "$entry")" == "mods.json" ]] && continue
    mv "$entry" "$tmp/assets/"
  done
  shopt -u dotglob
  mv "$tmp/assets" "$game/assets"
  rmdir "$tmp"
elif [[ -f "$game/assets/node-webkit.html" ]]; then
  echo "Game already under assets/ — keeping existing layout."
else
  echo "error: could not find node-webkit.html in $game (run sync-assets.sh)." >&2
  exit 1
fi

# --- 2. Obtain CCLoader -----------------------------------------------------------------
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
if [[ -z "$ccloader_src" ]]; then
  echo "Downloading CCLoader…"
  curl -sL "https://github.com/CCDirectLink/CCLoader/archive/refs/heads/master.zip" -o "$work/cc.zip"
  ( cd "$work" && unzip -q cc.zip )
  ccloader_src="$work/CCLoader-master"
fi
[[ -f "$ccloader_src/ccloader/index.html" ]] || { echo "error: no ccloader/index.html in $ccloader_src" >&2; exit 1; }

# --- 3. Overlay CCLoader ----------------------------------------------------------------
echo "Overlaying CCLoader from ${ccloader_src} ..."
rm -rf "$game/ccloader"
cp -R "$ccloader_src/ccloader" "$game/ccloader"
# Bundled mods that ship with CCLoader (simplify, version-display) live under assets/mods.
mkdir -p "$game/assets/mods"
if [[ -d "$ccloader_src/assets/mods" ]]; then
  cp -R "$ccloader_src/assets/mods/." "$game/assets/mods/"
fi

# cc-ios: force CCLoader to BROWSER mode even though the iOS host defines window.require
# (needed so CCModManager finds require("fs") for one-click installs). Without this,
# CCLoader's normalize.js would set isLocal and use NW.js-only callback fs paths.
cat > "$game/ccloader/js/normalize.js" <<'NORMALIZE'
String.prototype.endsWith = String.prototype.endsWith || function(end){
	return this.substr(this.length - end.length, end.length) === end;
};
// cc-ios: pinned to browser mode (host provides a require("fs") shim for mod installs).
window.isBrowser = true;
window.process = window.process || { once: () => {} };
NORMALIZE
echo "Patched ccloader/js/normalize.js to pin browser mode."

# --- 3b. Unpack any bundled packed mods (.ccmod) into folders ---------------------------
# CCLoader's browser mode can't read inside a packed .ccmod (that needs the NW.js X-Cmd
# server protocol). Unpack them to folder mods so they load on iOS — this includes
# CCModManager itself, which ships packed.
for ccmod in "$game"/assets/mods/*.ccmod; do
  [[ -e "$ccmod" ]] || continue
  dir="${ccmod%.ccmod}"
  echo "Unpacking $(basename "$ccmod") → $(basename "$dir")/"
  rm -rf "$dir"; mkdir -p "$dir"
  unzip -q -o "$ccmod" -d "$dir" && rm -f "$ccmod"
done

# --- 4. Add any user-specified mods -----------------------------------------------------
for mod in "${add_mods[@]:-}"; do
  [[ -z "$mod" ]] && continue
  echo "Adding mod: $mod"
  if [[ "$mod" == *.ccmod ]]; then
    dir="$game/assets/mods/$(basename "${mod%.ccmod}")"
    rm -rf "$dir"; mkdir -p "$dir"
    unzip -q -o "$mod" -d "$dir"
  elif [[ -d "$mod" ]]; then
    cp -R "$mod" "$game/assets/mods/$(basename "$mod")"
  else
    echo "  warning: $mod is neither a .ccmod nor a directory; skipping" >&2
  fi
done

# --- 5. Regenerate mods.json from whatever is in assets/mods/ ---------------------------
echo "Writing mods.json…"
python3 - "$game" <<'PY'
import json, os, sys
game = sys.argv[1]
mods_dir = os.path.join(game, "assets", "mods")
names = []
for entry in sorted(os.listdir(mods_dir)):
    p = os.path.join(mods_dir, entry)
    # Folder mods: a directory containing ccmod.json or package.json.
    if os.path.isdir(p) and (os.path.exists(os.path.join(p, "ccmod.json")) or
                             os.path.exists(os.path.join(p, "package.json"))):
        names.append(entry)
    # Packed mods keep their .ccmod filename in the list.
    elif entry.endswith(".ccmod"):
        names.append(entry)
open(os.path.join(game, "mods.json"), "w").write(json.dumps(names, indent="\t"))
print("  mods.json:", names)
PY

count=$(find "$game/assets/mods" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ')
echo "Done. CCLoader installed with $count item(s) in assets/mods/."
echo "Entry is now ccloader/index.html (app auto-detects it). Rebuild + reinstall the app."
