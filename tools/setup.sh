#!/usr/bin/env bash
# cc-ios one-shot onboarding: take a fresh clone to a buildable app.
#
# Does everything that CAN be automated:
#   1. Preflight (and optionally auto-install tools)         tools/preflight.sh
#   2. Locate your CrossCode assets                          tools/find-crosscode.sh
#   3. Copy assets into the app + transcode audio            tools/sync-assets.sh
#   4. (optional) Install CCLoader + the title-buttons mod   tools/setup-ccloader.sh
#   5. Generate the Xcode project                            xcodegen
#
# Then prints exactly how to run (Simulator) or build to a device.
#
# Usage:
#   tools/setup.sh                     # interactive
#   tools/setup.sh --yes               # non-interactive (accept first found game path)
#   tools/setup.sh --with-mods         # also install CCLoader + mods
#   tools/setup.sh --no-mods           # skip the mods prompt
#   tools/setup.sh --asset-root PATH   # use this CrossCode assets dir (skip discovery)
#   tools/setup.sh --skip-assets       # assume app/Resources/game is already populated
#   tools/setup.sh --fix               # let preflight auto-install brew tools
#   tools/setup.sh --sim               # on success, launch in the Simulator (run-sim.sh)
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ -t 1 ]]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; X=$'\033[0m'
else B=""; G=""; Y=""; R=""; X=""; fi
step() { printf '\n%s== %s ==%s\n' "$B" "$1" "$X"; }
die()  { printf '%serror:%s %s\n' "$R" "$X" "$1" >&2; exit 1; }

assume_yes=0; mods=ask; asset_root=""; skip_assets=0; fix=0; do_sim=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)     assume_yes=1; shift;;
    --with-mods)  mods=yes; shift;;
    --no-mods)    mods=no; shift;;
    --asset-root) asset_root="$2"; shift 2;;
    --skip-assets) skip_assets=1; shift;;
    --fix)        fix=1; shift;;
    --sim)        do_sim=1; shift;;
    -h|--help)    grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown arg: $1";;
  esac
done

# Non-interactive if asked, or if there's no TTY to prompt on.
interactive=1
{ [[ "$assume_yes" -eq 1 ]] || [[ ! -t 0 ]]; } && interactive=0

ask_yes_no() { # question, default(y/n) -> returns 0 for yes
  local q="$1" def="${2:-y}" ans=""
  if [[ "$interactive" -eq 0 ]]; then [[ "$def" == "y" ]]; return; fi
  local hint="[Y/n]"; [[ "$def" == "n" ]] && hint="[y/N]"
  printf '%s %s ' "$q" "$hint"; read -r ans || ans=""
  ans="${ans:-$def}"
  [[ "$ans" == [Yy]* ]]
}

# --- 1. Preflight ---------------------------------------------------------------------
step "Preflight"
pf_args=""; [[ "$fix" -eq 1 ]] && pf_args="--fix"
if ! tools/preflight.sh $pf_args; then
  die "preflight failed. Fix the blocking items above (try: tools/setup.sh --fix) and re-run."
fi

# --- 2. Locate CrossCode --------------------------------------------------------------
step "Locate CrossCode"
if [[ -z "$asset_root" ]]; then
  found=()
  while IFS= read -r line; do [[ -n "$line" ]] && found+=("$line"); done \
    < <(tools/find-crosscode.sh 2>/dev/null || true)

  if [[ "${#found[@]}" -eq 0 ]]; then
    echo "Couldn't find CrossCode automatically (looked in Steam, GOG, itch, /Applications)."
    if [[ "$interactive" -eq 1 ]]; then
      printf 'Path to your CrossCode assets dir (the folder with node-webkit.html): '
      read -r asset_root || asset_root=""
    fi
    [[ -n "$asset_root" ]] || die "no CrossCode assets path provided. Set one in tools/webkit-harness/asset-root.local or pass --asset-root."
  elif [[ "${#found[@]}" -eq 1 ]]; then
    asset_root="${found[0]}"
    echo "Found: $asset_root"
    ask_yes_no "Use this copy?" y || { asset_root=""; }
    if [[ -z "$asset_root" && "$interactive" -eq 1 ]]; then
      printf 'Enter the path to use instead: '; read -r asset_root || asset_root=""
    fi
    [[ -n "$asset_root" ]] || die "no CrossCode assets path chosen."
  else
    echo "Found multiple CrossCode installs:"
    i=1; for c in "${found[@]}"; do printf '  %d) %s\n' "$i" "$c"; i=$((i+1)); done
    if [[ "$interactive" -eq 1 ]]; then
      printf 'Choose [1-%d] (default 1): ' "${#found[@]}"; read -r pick || pick=""
      pick="${pick:-1}"
    else
      pick=1
    fi
    case "$pick" in (*[!0-9]*|"") pick=1;; esac
    [[ "$pick" -ge 1 && "$pick" -le "${#found[@]}" ]] || pick=1
    asset_root="${found[$((pick-1))]}"
    echo "Using: $asset_root"
  fi
fi

# Validate + persist the choice so every other tool agrees.
[[ -f "$asset_root/node-webkit.html" ]] || die "no node-webkit.html in: $asset_root"
printf '%s\n' "$asset_root" > tools/webkit-harness/asset-root.local
echo "Wrote tools/webkit-harness/asset-root.local"

# --- 3. Sync assets (+ transcode) -----------------------------------------------------
step "Assets"
if [[ "$skip_assets" -eq 1 ]]; then
  echo "Skipping (--skip-assets)."
elif [[ -f "app/Resources/game/node-webkit.html" || -f "app/Resources/game/assets/node-webkit.html" ]] \
     && ! ask_yes_no "app/Resources/game already populated — re-sync from source?" n; then
  echo "Keeping existing app/Resources/game."
else
  tools/sync-assets.sh || die "asset sync failed."
fi

# --- 4. CCLoader + mods (optional) ----------------------------------------------------
step "Mods (CCLoader)"
want_mods=0
case "$mods" in
  yes) want_mods=1;;
  no)  echo "Skipping (--no-mods).";;
  ask) ask_yes_no "Install CCLoader + the in-game mod manager + native title buttons?" y && want_mods=1;;
esac
if [[ "$want_mods" -eq 1 ]]; then
  tools/setup-ccloader.sh || die "CCLoader setup failed."
  tools/setup-ccloader.sh --add-mod mods/ccios-title-buttons || die "adding title-buttons mod failed."
fi

# --- 5. Generate the Xcode project ----------------------------------------------------
step "Xcode project"
if command -v xcodegen >/dev/null 2>&1; then
  ( cd app && xcodegen generate ) || die "xcodegen failed."
  echo "Generated app/cc-ios.xcodeproj"
else
  echo "${Y}xcodegen missing — skipping project generation.${X}"
fi

# --- Done -----------------------------------------------------------------------------
step "Done"
cat <<EOF
${G}Setup complete.${X}

Run in the iOS Simulator (no signing needed):
  ${B}tools/run-sim.sh${X}

Build & run on a connected iPhone (auto-detects device + signing team):
  ${B}tools/ios-build.sh${X}
  First time only: add your Apple ID in Xcode → Settings → Accounts, and on the
  iPhone enable Developer Mode + trust the developer cert. See README → "Apple
  Developer & signing".
EOF

if [[ "$do_sim" -eq 1 ]]; then
  step "Launching Simulator"
  exec tools/run-sim.sh
fi
