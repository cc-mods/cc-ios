#!/usr/bin/env bash
# Check (and optionally fix) everything cc-ios needs to build.
#
# Usage:
#   tools/preflight.sh          # report status; exit 0 if all hard requirements met
#   tools/preflight.sh --fix    # also auto-install brew tools + offer license/SDK fixes
#
# "Hard" requirements block the build; "soft" ones only limit optional features.
set -uo pipefail   # NB: not -e — we want to run every check and report all of them.

fix=0
[[ "${1:-}" == "--fix" ]] && fix=1

# Colour only when attached to a terminal.
if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; X=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; X=""
fi

hard_fail=0
soft_warn=0
ok()   { printf '  %s✓%s %s\n'        "$G" "$X" "$1"; }
bad()  { printf '  %s✗%s %s\n'        "$R" "$X" "$1"; hard_fail=$((hard_fail+1)); }
warn() { printf '  %s!%s %s\n'        "$Y" "$X" "$1"; soft_warn=$((soft_warn+1)); }
hint() { printf '      %s↳%s %s\n'    "$B" "$X" "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

printf '%scc-ios preflight%s\n' "$B" "$X"

# --- macOS ----------------------------------------------------------------------------
if [[ "$(uname -s)" == "Darwin" ]]; then
  ok "macOS ($(sw_vers -productVersion 2>/dev/null || echo '?'))"
else
  bad "Not macOS — building/signing an iOS app requires a Mac."
fi

# --- Full Xcode -----------------------------------------------------------------------
xc="$(xcode-select -p 2>/dev/null || true)"
if [[ "$xc" == *Xcode.app* ]]; then
  ok "Full Xcode selected ($(xcodebuild -version 2>/dev/null | head -1 || echo '?'))"
else
  bad "Full Xcode not selected (got: ${xc:-none})."
  hint "Install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

# --- Xcode license --------------------------------------------------------------------
if [[ "$xc" == *Xcode.app* ]]; then
  if xcodebuild -version >/dev/null 2>&1; then
    ok "Xcode license accepted"
  else
    bad "Xcode license not accepted."
    if [[ "$fix" -eq 1 && -t 0 ]]; then
      hint "Running: sudo xcodebuild -license accept"
      sudo xcodebuild -license accept && { ok "license accepted"; hard_fail=$((hard_fail-1)); }
    else
      hint "Run: sudo xcodebuild -license accept"
    fi
  fi
fi

# --- iOS device SDK -------------------------------------------------------------------
if xcodebuild -showsdks 2>/dev/null | grep -qi 'iphoneos'; then
  ok "iOS SDK installed"
else
  bad "iOS platform/SDK not installed."
  if [[ "$fix" -eq 1 ]]; then
    hint "Running: xcodebuild -downloadPlatform iOS (large download)…"
    xcodebuild -downloadPlatform iOS && { ok "iOS platform installed"; hard_fail=$((hard_fail-1)); }
  else
    hint "Run: xcodebuild -downloadPlatform iOS   (or Xcode → Settings → Components)"
  fi
fi

# --- iOS Simulator runtime (soft: only needed for the Simulator path) -----------------
if xcrun simctl list runtimes 2>/dev/null | grep -qi 'iOS'; then
  ok "iOS Simulator runtime available"
else
  warn "No iOS Simulator runtime (device builds still work)."
  hint "Get one in Xcode → Settings → Components, or: xcodebuild -downloadPlatform iOS"
fi

# --- swift ----------------------------------------------------------------------------
if have swift; then ok "swift ($(swift --version 2>/dev/null | head -1 | sed 's/ (.*//'))"
else bad "swift not found (ships with Xcode)."; fi

# --- Homebrew + tools -----------------------------------------------------------------
brew_ok=1
if have brew; then
  ok "Homebrew"
else
  brew_ok=0
  warn "Homebrew not found — can't auto-install xcodegen/ffmpeg."
  hint "Install from https://brew.sh, or install xcodegen + ffmpeg by hand."
fi

ensure_brew_tool() { # name, purpose
  local tool="$1" purpose="$2"
  if have "$tool"; then
    ok "$tool ($purpose)"
    return
  fi
  bad "$tool not found — $purpose."
  if [[ "$fix" -eq 1 && "$brew_ok" -eq 1 ]]; then
    hint "Running: brew install $tool"
    brew install "$tool" && { ok "$tool installed"; hard_fail=$((hard_fail-1)); }
  else
    hint "Run: brew install $tool"
  fi
}
ensure_brew_tool xcodegen "generates the Xcode project"
ensure_brew_tool ffmpeg   "transcodes Ogg→M4A for iOS audio"

# --- python3 (soft: used for mods.json + VDF helpers) ---------------------------------
if have python3; then ok "python3"
else warn "python3 not found (only needed for CCLoader mod setup)."; fi

# --- Summary --------------------------------------------------------------------------
echo
if [[ "$hard_fail" -eq 0 ]]; then
  printf '%s✓ Ready to build.%s' "$G" "$X"
  [[ "$soft_warn" -gt 0 ]] && printf ' (%d optional item(s) to note above.)' "$soft_warn"
  echo
  exit 0
else
  printf '%s✗ %d blocking issue(s).%s ' "$R" "$hard_fail" "$X"
  [[ "$fix" -eq 0 ]] && printf 'Re-run with --fix to auto-install tools.'
  echo
  exit 1
fi
