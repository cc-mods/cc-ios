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
step "Signing team"
if [[ -z "$team_id" ]]; then
  team_id="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -iE "Apple Development" | grep -oE "\([A-Z0-9]{10}\)" | tr -d '()' | head -1 || true)"
fi
if [[ -z "$team_id" ]]; then
  echo "error: no Apple Development signing identity found." >&2
  echo "Add your Apple ID in Xcode → Settings → Accounts, then build once in Xcode to mint a cert." >&2
  exit 1
fi
echo "Team ID: $team_id"
echo "Bundle ID: $bundle_id"

# --- 3. Device UDID ----------------------------------------------------------------
step "Device"
if [[ -z "$device_udid" ]]; then
  device_udid="$(xcrun devicectl list devices 2>/dev/null \
    | awk '/available|connected/ && /iPhone|iPad/ {print $(NF-1); exit}' || true)"
fi
if [[ -z "$device_udid" ]]; then
  echo "error: no connected device found. Connect iPhone, enable Developer Mode, trust the Mac." >&2
  echo "Devices seen:" >&2
  xcrun devicectl list devices >&2 || true
  exit 1
fi
echo "Device UDID: $device_udid"

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
  -destination "platform=iOS,id=$device_udid" \
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
xcrun devicectl device install app --device "$device_udid" "$app_path"

# --- 7. Launch ---------------------------------------------------------------------
if [[ "$do_launch" -eq 1 ]]; then
  step "Launch"
  xcrun devicectl device process launch --device "$device_udid" "$bundle_id" || {
    echo "note: launch failed (often a first-run trust prompt)." >&2
    echo "On the iPhone: Settings → General → VPN & Device Management → trust your developer cert, then relaunch." >&2
  }
fi

step "Done"
echo "cc-ios installed on device $device_udid as $bundle_id"
