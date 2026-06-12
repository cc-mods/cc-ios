#!/usr/bin/env bash
# cc-ios — interactive setup with a live, verifiable status board.
#
# A friendly front-end over the same tools/*.sh that `setup.sh` drives, but it
# (a) probes your current state up front so every stage shows a real ✓/✗,
# (b) walks you through only what's missing, and (c) verifies each step after it
# runs (tool versions, asset counts, the .xcodeproj, a reachable save-server).
#
# It never reimplements the underlying scripts — it calls preflight.sh,
# find-crosscode.sh, sync-assets.sh, setup-ccloader.sh, xcodegen, setup-sync.sh
# and save-server.sh, then proves the result.
#
# Usage:
#   tools/setup-tui.sh            # interactive board (this is the friendly path)
#   tools/setup-tui.sh --check    # probe + print status, then exit (read-only)
#   tools/setup-tui.sh --port N   # save-sync port to verify (default 8765)
#
# Headless/CI: use tools/setup.sh (scriptable, accepts --yes/--with-mods/…).
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

check_only=0
sync_port=8765
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)   check_only=1; shift;;
    --port)    sync_port="$2"; shift 2;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2;;
  esac
done

# --- capabilities: only draw a real UI on an interactive UTF-8 terminal --------------
use_ui=1
{ [[ -t 1 && -t 0 ]] && [[ "${TERM:-dumb}" != dumb ]] && [[ -z "${NO_COLOR:-}" ]]; } || use_ui=0

if [[ "$use_ui" -eq 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YEL=$'\033[33m'; CYN=$'\033[36m'; X=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; CYN=""; X=""
fi

# Restore the cursor on any exit (we hide it while drawing).
cleanup() { [[ "$use_ui" -eq 1 ]] && printf '\033[?25h'; }
trap cleanup EXIT INT TERM

# --- stage model (bash 3.2: parallel indexed arrays) ---------------------------------
stage_id=(   env             assets             mods              project          run               sync )
stage_name=( "Toolchain"     "CrossCode assets" "Mods (CCLoader)" "Xcode project"  "Run target"      "PC save sync (Tailscale)" )
stage_state=( pending pending pending pending pending pending )   # pending|run|ok|warn|fail|skip
stage_detail=( "" "" "" "" "" "" )
SPIN_FRAME="·"

idx_of() { local i=0; for i in 0 1 2 3 4 5; do [[ "${stage_id[$i]}" == "$1" ]] && { printf '%s' "$i"; return; }; done; printf -- '-1'; }
set_stage() { local i; i="$(idx_of "$1")"; [[ "$i" -ge 0 ]] || return; stage_state[$i]="$2"; stage_detail[$i]="${3:-}"; }

glyph() { # state
  case "$1" in
    ok)   printf '%s✓%s' "$GRN" "$X";;
    warn) printf '%s!%s' "$YEL" "$X";;
    fail) printf '%s✗%s' "$RED" "$X";;
    run)  printf '%s%s%s' "$CYN" "$SPIN_FRAME" "$X";;
    skip) printf '%s–%s' "$DIM" "$X";;
    *)    printf '%s○%s' "$DIM" "$X";;
  esac
}

render() { # optional footer text
  if [[ "$use_ui" -eq 0 ]]; then return; fi
  printf '\033[?25l\033[H\033[2J'
  printf '%s  cc-ios setup%s   %sa live, verifiable walkthrough%s\n' "$BOLD" "$X" "$DIM" "$X"
  printf '%s  ────────────────────────────────────────────────%s\n' "$DIM" "$X"
  local i st de
  for i in 0 1 2 3 4 5; do
    st="${stage_state[$i]}"; de="${stage_detail[$i]:-}"
    printf '   %s  %-26s %s%s%s\n' "$(glyph "$st")" "${stage_name[$i]}" "$DIM" "$de" "$X"
  done
  printf '%s  ────────────────────────────────────────────────%s\n' "$DIM" "$X"
  printf '   %s○%s todo  %s✓%s done  %s!%s note  %s✗%s failed  %s–%s skipped\n' \
    "$DIM" "$X" "$GRN" "$X" "$YEL" "$X" "$RED" "$X" "$DIM" "$X"
  if [[ -n "${1:-}" ]]; then printf '\n%s\n' "$1"; fi
}

# Print a one-line status (plain/non-TTY mode) when a stage changes.
note() { [[ "$use_ui" -eq 0 ]] && printf '[%s] %s\n' "$1" "${2:-}"; }

# --- run a non-interactive command with a spinner + captured log ---------------------
# run_step <stage_id> <description> -- <cmd...>
run_step() {
  local id="$1" desc="$2"; shift 2; [[ "$1" == "--" ]] && shift
  local log; log="$(mktemp)"
  set_stage "$id" run "$desc"
  if [[ "$use_ui" -eq 0 ]]; then
    note "$id" "$desc"
    "$@" >"$log" 2>&1; local rc=$?
    [[ "$rc" -eq 0 ]] || { sed 's/^/    /' "$log" | tail -20; }
    rm -f "$log"; return "$rc"
  fi
  "$@" >"$log" 2>&1 &
  local pid=$! frames='⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏' fa i=0 last=""
  fa=($frames)
  while kill -0 "$pid" 2>/dev/null; do
    SPIN_FRAME="${fa[$((i % ${#fa[@]}))]}"
    last="$(tail -1 "$log" 2>/dev/null | tr -dc '[:print:]' | cut -c1-40)"
    set_stage "$id" run "${desc}${last:+ — $last}…"
    render "   $(glyph run) working…  (Ctrl-C to abort)"
    sleep 0.12; i=$((i+1))
  done
  wait "$pid"; local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    set_stage "$id" fail "exit $rc"
    render "$(printf '%s── last output ─────────────────────────%s' "$RED" "$X")"
    sed 's/^/   /' "$log" | tail -16
    printf '\n'
  fi
  rm -f "$log"; return "$rc"
}

# Ask for a single key; Enter returns the default. Echoes the chosen char.
ask_key() { # prompt default
  local p="$1" def="$2" k=""
  render "$p"
  IFS= read -rsn 1 k 2>/dev/null || k=""
  case "$k" in ""|$'\n'|$'\r') k="$def";; esac
  printf '%s' "$k"
}

# ====================================================================================
# Probes — cheap reads that set each stage's initial (and post-action) status.
# ====================================================================================
probe_env() {
  if xcode-select -p 2>/dev/null | grep -q 'Xcode.app' \
     && command -v swift >/dev/null 2>&1 \
     && command -v xcodegen >/dev/null 2>&1 \
     && command -v ffmpeg >/dev/null 2>&1; then
    set_stage env ok "Xcode · swift · xcodegen · ffmpeg"
  else
    set_stage env pending "run a full preflight check"
  fi
}
probe_assets() {
  local g="app/Resources/game"
  if [[ -f "$g/node-webkit.html" || -f "$g/assets/node-webkit.html" ]]; then
    local n layout="vanilla"
    n="$(find "$g" -name '*.m4a' 2>/dev/null | wc -l | tr -d ' ')"
    [[ -f "$g/ccloader/index.html" ]] && layout="CCLoader"
    set_stage assets ok "$layout layout · $n transcoded .m4a"
  else
    set_stage assets pending "not synced yet"
  fi
}
probe_mods() {
  if [[ -f "app/Resources/game/ccloader/index.html" ]]; then
    set_stage mods ok "CCLoader + mods overlaid"
  else
    set_stage mods pending "optional"
  fi
}
probe_project() {
  if [[ -d "app/cc-ios.xcodeproj" ]]; then set_stage project ok "app/cc-ios.xcodeproj"
  else set_stage project pending "not generated"; fi
}
probe_run() {
  local sim=""
  xcrun simctl list runtimes 2>/dev/null | grep -qi 'iOS' && sim="Simulator ready"
  if [[ -n "$sim" ]]; then set_stage run ok "$sim"; else set_stage run warn "no Simulator runtime"; fi
}
probe_sync() {
  if launchctl list 2>/dev/null | grep -q 'com.ccios.save-server'; then
    set_stage sync ok "save-server service loaded"
  elif [[ -f cc-sync.json ]]; then
    set_stage sync warn "configured; server not running"
  else
    set_stage sync pending "optional"
  fi
}
probe_all() { probe_env; probe_assets; probe_mods; probe_project; probe_run; probe_sync; }

# ====================================================================================
# Stage actions
# ====================================================================================
do_env() {
  local i; i="$(idx_of env)"
  [[ "${stage_state[$i]}" == ok ]] && return 0
  run_step env "checking toolchain" -- tools/preflight.sh || {
    local k; k="$(ask_key "$(printf '   %sPreflight found blockers.%s  [f] auto-install tools  [s] skip  [q] quit' "$YEL" "$X")" f)"
    case "$k" in
      f|F) printf '\033[?25h'; tools/preflight.sh --fix || true;;
      q|Q) exit 0;;
      *)   set_stage env warn "skipped — fix blockers before building"; return 0;;
    esac
  }
  probe_env
}

do_assets() {
  local i; i="$(idx_of assets)"
  if [[ "${stage_state[$i]}" == ok ]]; then
    local k; k="$(ask_key "   ${stage_detail[$i]}.  [Enter] keep  [r] re-sync from source (wipes CCLoader)  [s] skip" "")"
    case "$k" in r|R) :;; *) return 0;; esac
    if [[ -f "app/Resources/game/ccloader/index.html" ]]; then
      local c; c="$(ask_key "$(printf '   %sRe-sync deletes the CCLoader overlay (you can re-add mods after).%s  [y] proceed  [N] cancel' "$YEL" "$X")" n)"
      case "$c" in y|Y) :;; *) return 0;; esac
    fi
  fi

  # Pick the CrossCode source (find-crosscode lists candidates; user chooses).
  local found=() line
  while IFS= read -r line; do [[ -n "$line" ]] && found+=("$line"); done \
    < <(tools/find-crosscode.sh 2>/dev/null || true)

  local choice=""
  if [[ "${#found[@]}" -eq 1 ]]; then
    choice="${found[0]}"
    local k; k="$(ask_key "   Found: ${found[0]}  [Enter] use  [o] other path  [s] skip" "")"
    case "$k" in o|O) choice="";; s|S) set_stage assets skip "skipped"; return 0;; esac
  elif [[ "${#found[@]}" -gt 1 ]]; then
    render "   Multiple CrossCode installs found:"
    local n=1 c; for c in "${found[@]}"; do printf '     %d) %s\n' "$n" "$c"; n=$((n+1)); done
    printf '   Choose [1-%d], or 0 for another path: ' "${#found[@]}"
    local pick; read -r pick || pick=1; pick="${pick:-1}"
    case "$pick" in (*[!0-9]*) pick=1;; esac
    if [[ "$pick" -ge 1 && "$pick" -le "${#found[@]}" ]]; then choice="${found[$((pick-1))]}"; fi
  fi
  if [[ -z "$choice" ]]; then
    render "   Path to your CrossCode folder (contains node-webkit.html):"
    printf '   > '; read -r choice || choice=""
  fi
  if [[ -z "$choice" || ! -f "$choice/node-webkit.html" ]]; then
    set_stage assets fail "no node-webkit.html at: ${choice:-<none>}"; ask_key "   [Enter] continue" "" >/dev/null; return 1
  fi

  printf '%s\n' "$choice" > tools/webkit-harness/asset-root.local
  run_step assets "syncing + transcoding audio" -- tools/sync-assets.sh && probe_assets
  probe_mods
}

do_mods() {
  local i; i="$(idx_of mods)"
  [[ "${stage_state[$i]}" == ok ]] && return 0
  local ai; ai="$(idx_of assets)"
  if [[ "${stage_state[$ai]}" != ok && "${stage_state[$ai]}" != skip ]]; then
    set_stage mods warn "needs assets first"; return 0
  fi
  local k; k="$(ask_key "   Install CCLoader + in-game Mod Manager + native title buttons?  [Y] yes  [s] skip" y)"
  case "$k" in s|S|n|N) set_stage mods skip "skipped"; return 0;; esac
  run_step mods "overlaying CCLoader" -- tools/setup-ccloader.sh \
    && run_step mods "adding title-buttons mod" -- tools/setup-ccloader.sh --add-mod mods/ccios-title-buttons
  probe_mods; probe_assets
}

do_project() {
  local i; i="$(idx_of project)"
  [[ "${stage_state[$i]}" == ok ]] && return 0
  if ! command -v xcodegen >/dev/null 2>&1; then
    set_stage project warn "xcodegen missing (run Toolchain stage)"; return 0
  fi
  run_step project "generating Xcode project" -- sh -c 'cd app && xcodegen generate'
  probe_project
}

do_run() {
  local i; i="$(idx_of run)"
  # Best-effort: is a physical device connected?
  local dev="" tmp; tmp="$(mktemp)"
  xcrun devicectl list devices --json-output "$tmp" >/dev/null 2>&1 || true
  dev="$(python3 - "$tmp" <<'PY' 2>/dev/null
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
for x in d.get("result",{}).get("devices",[]):
    if x.get("connectionProperties",{}).get("tunnelState") in ("connected","connecting"):
        print(x.get("deviceProperties",{}).get("name","iPhone")); break
PY
)"
  rm -f "$tmp"
  local sim=""; xcrun simctl list runtimes 2>/dev/null | grep -qi 'iOS' && sim="yes"
  if [[ -n "$dev" && -n "$sim" ]]; then set_stage run ok "device: $dev · Simulator ready"
  elif [[ -n "$dev" ]]; then set_stage run ok "device: $dev"
  elif [[ -n "$sim" ]]; then set_stage run ok "Simulator ready (no device connected)"
  else set_stage run warn "no Simulator runtime and no device"; fi
}

do_sync() {
  local i; i="$(idx_of sync)"
  local k; k="$(ask_key "   Set up wireless save sync with this Mac over Tailscale?  [y] yes  [N] skip" n)"
  case "$k" in y|Y) :;; *) [[ "${stage_state[$i]}" == ok ]] || set_stage sync skip "skipped"; return 0;; esac

  run_step sync "writing + pushing cc-sync.json" -- tools/setup-sync.sh --port "$sync_port" || {
    ask_key "   (is the iPhone connected + unlocked?)  [Enter] continue" "" >/dev/null
  }
  local s; s="$(ask_key "   Run the save hub persistently (launchd, survives reboots)?  [Y] yes  [s] skip" y)"
  case "$s" in s|S|n|N) :;; *) run_step sync "installing save-server service" -- tools/save-server.sh install --port "$sync_port";; esac

  # Verify: hit /status and surface the save's size + hash as proof.
  local status; status="$(curl -s --max-time 5 "http://127.0.0.1:${sync_port}/status" 2>/dev/null || true)"
  if [[ -n "$status" ]]; then
    local size sha
    size="$(printf '%s' "$status" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("size",0))' 2>/dev/null || echo '?')"
    sha="$(printf '%s' "$status" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("sha256","")[:12])' 2>/dev/null || echo '')"
    set_stage sync ok "server up · ${size}B · sha ${sha}…"
  else
    probe_sync
  fi
}

# ====================================================================================
# Main
# ====================================================================================
if [[ "$use_ui" -eq 0 && "$check_only" -eq 0 ]]; then
  printf 'setup-tui needs an interactive terminal. For headless/CI use: tools/setup.sh\n' >&2
  probe_all
  # fall through to print a plain status so the call still yields something useful.
  check_only=1
fi

probe_all

if [[ "$check_only" -eq 1 ]]; then
  if [[ "$use_ui" -eq 1 ]]; then
    render "   Read-only check. Run without --check to set things up."
  else
    printf 'cc-ios status\n'
    local_i=0
    for local_i in 0 1 2 3 4 5; do
      printf '  [%-7s] %-26s %s\n' "${stage_state[$local_i]}" "${stage_name[$local_i]}" "${stage_detail[$local_i]:-}"
    done
  fi
  exit 0
fi

render "   Press Enter to begin. We'll only run what's missing."
ask_key "" "" >/dev/null

do_env;     render; 
do_assets;  render
do_mods;    render
do_project; render
do_run;     render
do_sync

# --- final board + next steps ---------------------------------------------------------
render
printf '\n%s  Setup summary%s\n' "$BOLD" "$X"
printf '  Run in the iOS Simulator (no signing):   %stools/run-sim.sh%s\n' "$BOLD" "$X"
printf '  Build + run on a connected iPhone:       %stools/ios-build.sh%s\n' "$BOLD" "$X"
ai="$(idx_of sync)"
if [[ "${stage_state[$ai]}" == ok ]]; then
  printf '  Save sync is live; saves push on change and pull at app launch.\n'
fi
printf '\n'
