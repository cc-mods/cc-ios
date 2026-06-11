#!/usr/bin/env bash
# Build, sign, install, and launch cc-ios on a connected iPhone — fully from the CLI.
#
# Standalone runtime: assets are bundled into the .app, saves live in localStorage on the
# device. The only host dependency is this build/sign/install step (inherent to sideloading).
#
# Usage:
#   tools/ios-build.sh [--bundle-id ID] [--team TEAMID] [--device UDID] [--no-launch]
#
# Auto-detects: device UDID (first connected), Team ID (from signing identity), and
# regenerates the Xcode project. Pass flags to override.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$repo_root/app"
scheme="cc-ios"
project="$app_dir/cc-ios.xcodeproj"

bundle_id="${CCIOS_BUNDLE_ID:-com.example.ccios}"
team_id="${CCIOS_TEAM_ID:-}"
device_udid="${CCIOS_DEVICE_UDID:-}"
do_launch=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-id) bundle_id="$2"; shift 2;;
    --team)      team_id="$2"; shift 2;;
    --device)    device_udid="$2"; shift 2;;
    --no-launch) do_launch=0; shift;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

step() { printf '\n=== %s ===\n' "$1"; }

# --- 0. Preconditions --------------------------------------------------------------
step "Toolchain"
if ! xcode-select -p | grep -q "Xcode.app"; then
  echo "error: full Xcode not selected. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi
xcodebuild -version | head -1

# --- 1. Assets ---------------------------------------------------------------------
step "Assets"
if [[ ! -f "$app_dir/Resources/game/node-webkit.html" ]]; then
  echo "Game assets not bundled yet; running sync-assets.sh"
  "$repo_root/tools/sync-assets.sh"
else
  echo "Assets present: $(find "$app_dir/Resources/game" -type f | wc -l | tr -d ' ') files"
fi

# --- 2. Team ID --------------------------------------------------------------------
# Prefer the team of the Apple ID actually signed into Xcode (authoritative — this is the
# account that can mint profiles). Only fall back to a keychain signing cert, which may be
# stale / belong to an account no longer signed in (that mismatch causes the dreaded
# "No Account for Team XXXX" build error).
step "Signing team"
if [[ -z "$team_id" ]]; then
  team_id="$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | plutil -convert json -o - - 2>/dev/null \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
teams = []
for v in d.values():
    for t in (v if isinstance(v, list) else [v]):
        if isinstance(t, dict) and t.get('teamID'):
            teams.append((0 if t.get('isFreeProvisioningTeam') else 1, t['teamID']))
teams.sort()
print(teams[0][1] if teams else '')
" 2>/dev/null || true)"
fi
if [[ -z "$team_id" ]]; then
  # Fallback: a signing identity in the keychain (works when it matches a signed-in account).
  team_id="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -iE "Apple Development" | grep -oE "\([A-Z0-9]{10}\)" | tr -d '()' | head -1 || true)"
fi
if [[ -z "$team_id" ]]; then
  echo "error: no signing team found." >&2
  echo "Add your Apple ID in Xcode → Settings → Accounts (a free account is fine)." >&2
  exit 1
fi
echo "Team ID: $team_id"
echo "Bundle ID: $bundle_id"

# --- 3. Device (resolve BOTH ids) --------------------------------------------------
# xcodebuild's -destination needs the hardware UDID (00008xxx-…), while
# `devicectl … --device` takes the coredevice identifier (a UUID). Detect both from the
# JSON so we don't fragile-parse the human-readable table (model names contain spaces).
step "Device"
install_id="$device_udid"   # for devicectl (identifier); also honoured if user passed --device
build_udid=""               # for xcodebuild (hardware UDID)
if [[ -z "$device_udid" || -z "$build_udid" ]]; then
  tmp_dev="$(mktemp)"
  xcrun devicectl list devices --json-output "$tmp_dev" >/dev/null 2>&1 || true
  read -r det_ident det_udid < <(python3 - "$tmp_dev" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for dev in d.get("result", {}).get("devices", []):
    cp = dev.get("connectionProperties", {})
    if cp.get("tunnelState") in ("connected", "connecting") or cp.get("pairingState") == "paired":
        ident = dev.get("identifier", "")
        udid = dev.get("hardwareProperties", {}).get("udid", "")
        print(ident, udid)
        break
PY
)
  rm -f "$tmp_dev"
  [[ -z "$install_id" ]] && install_id="$det_ident"
  build_udid="$det_udid"
fi
# If the user supplied --device but we couldn't read a hardware UDID, fall back to it.
[[ -z "$build_udid" ]] && build_udid="$install_id"
if [[ -z "$install_id" || -z "$build_udid" ]]; then
  echo "error: no connected device found. Connect iPhone, enable Developer Mode, trust the Mac." >&2
  echo "Devices seen:" >&2
  xcrun devicectl list devices >&2 || true
  exit 1
fi
echo "Device identifier: $install_id"
echo "Hardware UDID:     $build_udid"

# --- 4. Regenerate project ---------------------------------------------------------
step "Project"
if command -v xcodegen >/dev/null 2>&1; then
  ( cd "$app_dir" && xcodegen generate )
else
  echo "warning: xcodegen not installed; using existing project" >&2
fi

# --- 5. Build (device, signed) -----------------------------------------------------
step "Build"
derived="$repo_root/build/DerivedData"
xcodebuild \
  -project "$project" \
  -scheme "$scheme" \
  -configuration Debug \
  -destination "platform=iOS,id=$build_udid" \
  -derivedDataPath "$derived" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$team_id" \
  PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
  CODE_SIGN_IDENTITY="Apple Development" \
  build

app_path="$(find "$derived/Build/Products/Debug-iphoneos" -maxdepth 1 -name '*.app' | head -1)"
if [[ -z "$app_path" ]]; then
  echo "error: built .app not found" >&2; exit 1
fi
echo "Built: $app_path"

# --- 6. Install --------------------------------------------------------------------
step "Install"
xcrun devicectl device install app --device "$install_id" "$app_path"

# --- 7. Launch ---------------------------------------------------------------------
if [[ "$do_launch" -eq 1 ]]; then
  step "Launch"
  xcrun devicectl device process launch --device "$install_id" "$bundle_id" || {
    echo "note: launch failed (often a first-run trust prompt)." >&2
    echo "On the iPhone: Settings → General → VPN & Device Management → trust your developer cert, then relaunch." >&2
  }
fi

step "Done"
echo "cc-ios installed on device $install_id as $bundle_id"
