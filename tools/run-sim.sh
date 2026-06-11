#!/usr/bin/env bash
# Build, install, and launch cc-ios in the iOS Simulator — one command.
#
# No code signing needed (the Simulator runs unsigned). Picks a booted simulator
# if one is running, otherwise boots a sensible iPhone.
#
# Usage:
#   tools/run-sim.sh                 # auto-pick a simulator, build, install, launch
#   tools/run-sim.sh --device NAME   # use a specific simulator (e.g. "iPhone 16 Pro")
#   tools/run-sim.sh --no-launch     # build + install only
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

bundle_id="${CCIOS_BUNDLE_ID:-com.example.ccios}"
scheme="cc-ios"
project="app/cc-ios.xcodeproj"
device_name=""
do_launch=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device_name="$2"; shift 2;;
    --no-launch) do_launch=0; shift;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

step() { printf '\n=== %s ===\n' "$1"; }

# --- 0. Sanity ------------------------------------------------------------------------
if [[ ! -f "app/Resources/game/node-webkit.html" && ! -f "app/Resources/game/assets/node-webkit.html" ]]; then
  echo "warning: app/Resources/game has no game assets — run tools/setup.sh first." >&2
fi

# --- 1. Project -----------------------------------------------------------------------
if [[ ! -d "$project" ]]; then
  step "Generate project"
  command -v xcodegen >/dev/null 2>&1 || { echo "error: xcodegen not installed (brew install xcodegen)." >&2; exit 1; }
  ( cd app && xcodegen generate )
fi

# --- 2. Pick a simulator --------------------------------------------------------------
step "Simulator"
udid=""
if [[ -n "$device_name" ]]; then
  udid="$(xcrun simctl list devices available 2>/dev/null \
    | grep -F "$device_name (" | grep -Eo '[0-9A-Fa-f-]{36}' | head -1 || true)"
  [[ -n "$udid" ]] || { echo "error: no available simulator named '$device_name'." >&2;
    echo "Available:" >&2; xcrun simctl list devices available | grep iPhone >&2; exit 1; }
else
  # Prefer an already-booted device, else the first available iPhone.
  udid="$(xcrun simctl list devices booted 2>/dev/null | grep -Eo '[0-9A-Fa-f-]{36}' | head -1 || true)"
  if [[ -z "$udid" ]]; then
    udid="$(xcrun simctl list devices available 2>/dev/null | grep iPhone | grep -Eo '[0-9A-Fa-f-]{36}' | head -1 || true)"
  fi
  [[ -n "$udid" ]] || { echo "error: no iOS simulators available. Add one in Xcode → Settings → Components." >&2; exit 1; }
fi
name="$(xcrun simctl list devices | grep "$udid" | sed -E 's/ *\(.*//' | head -1 | xargs)"
echo "Target: ${name:-simulator} ($udid)"

xcrun simctl boot "$udid" >/dev/null 2>&1 || true   # already-booted → harmless
open -a Simulator || true

# --- 3. Build -------------------------------------------------------------------------
step "Build"
derived="build"
xcodebuild \
  -project "$project" \
  -scheme "$scheme" \
  -configuration Debug \
  -destination "id=$udid" \
  -derivedDataPath "$derived" \
  build

app_path="$(find "$derived/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name '*.app' | head -1)"
[[ -n "$app_path" ]] || { echo "error: built .app not found." >&2; exit 1; }
echo "Built: $app_path"

# --- 4. Install + launch --------------------------------------------------------------
step "Install"
xcrun simctl install "$udid" "$app_path"

if [[ "$do_launch" -eq 1 ]]; then
  step "Launch"
  xcrun simctl launch "$udid" "$bundle_id" || true
  echo "Launched $bundle_id. In the Simulator, rotate to landscape with ⌘→ if needed."
fi
