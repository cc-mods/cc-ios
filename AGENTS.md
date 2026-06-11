# AGENTS.md

Guidance for AI coding agents (and humans) working in **cc-ios**. Read this before making
changes. It captures the hard-won, non-obvious knowledge that keeps this project working.

This file follows the [agents.md](https://agents.md) convention and is intended to be the single
source of truth for how to work here. `.github/copilot-instructions.md` and `CONTRIBUTING.md`
point back to it.

---

## What this project is

cc-ios runs **CrossCode** (a desktop HTML5/Impact-engine game shipped in NW.js) on iPhone/iPad by
wrapping its web runtime in a native `WKWebView`. It is the iOS analog of CrossAndroid. The app
is a thin host: it serves the game's own files over a custom URL scheme and injects a small amount
of JavaScript so the game boots in **browser mode**.

It is **sideload-only** and **brings-your-own-assets**. See `README.md` for the user-facing story.

---

## 🚨 Golden rules (do not violate)

1. **Never commit CrossCode game assets.** They are copyrighted and the user supplies their own.
   `app/Resources/game/` and `*.ccmod` are git-ignored — keep it that way. If you add a path that
   could contain game files, add it to `.gitignore` first. Verify with `git status` before every
   commit that no game media (`.png`, `.ogg`, `.m4a`, `game.compiled.js`, `node-webkit.html`, …)
   is staged.
2. **Never commit personal or machine-specific data.** No real names/emails, no `/Users/<name>`
   absolute paths, no Apple Team IDs or signing cert IDs, no device UDIDs, no Tailscale/LAN IPs,
   no API tokens. Use `$HOME`, `userDomainMask`, and env vars/flags instead. Commits must use a
   privacy-preserving git identity (a GitHub `noreply` address), not a corporate email.
3. **Keep the iOS app and macOS harness on the same `Shared/CCWebHost` code.** Anything proven in
   the harness must carry to the device unchanged. Don't fork host logic per platform.
4. **Prove changes in the macOS harness before claiming they work.** See
   [Development workflow](#development-workflow). The bar is: game boots, `jsErrors == 0`, no
   `CRITICAL BUG` screen.
5. **Don't write scripts to edit source files.** Use normal editing. Shell/Python string-rewriting
   of source is fragile and banned.

---

## Setup & common commands

```bash
make doctor     # check the toolchain (Xcode, SDKs, xcodegen, ffmpeg, …); --fix installs brew tools
make setup      # one-shot onboarding: preflight → find game → sync+transcode assets → project
make sim        # build + run in the iOS Simulator (no signing)
make device     # build + sign + install on a connected iPhone
make harness    # boot the game in a macOS WKWebView (writes proof.png)
make help       # list all targets
```

Lower-level equivalents live in `tools/` (each script self-documents with `-h`). The macOS
harness is a SwiftPM target:

```bash
swift build                                   # build CCWebHost + webkit-harness
swift run webkit-harness --help               # all harness flags
```

There is **no unit-test suite**. The harness *is* the test: it boots the real game headlessly
(well, in an offscreen window) and reports JS errors, 404s, and `ig.ready`.

---

## Architecture & layout

```
Shared/CCWebHost/        Cross-platform WebKit host (THE core; used by both app and harness)
  GameSchemeHandler.swift  Serves ccgame:// from the bundle. Range support; dir→200; audio M4A
                           patch; force-browser patch; mods overlay; synthesizes mods.json.
  Bootstrap.swift          All injected JS (documentStart/documentEnd WKUserScripts):
                           NW.js neutralization, console→native bridge, save hook, gamepad shim,
                           require/fs shim, FPS overlay.
  GameWebHost.swift        Builds WKWebViewConfiguration; resolves the entry URL (auto-detects
                           ccloader/index.html); wires script-message handlers.
  ModFSBridge.swift        Native async fs bridge (WKScriptMessageHandlerWithReply) for one-click
                           mod installs into a writable Documents/mods overlay.
  ZipReader.swift          Minimal ZIP/deflate reader to unpack .ccmod packages on device.

app/                     iOS app (SwiftUI). Consumes Shared/CCWebHost.
  Sources/                 CCIOSApp, GameView (owns the bridges), AudioSession, ControllerBridge,
                           SaveBridge, SaveSyncClient, ControlBridge.
  project.yml              XcodeGen spec. Bundle ID / team are NOT hard-coded (passed at build).
  Resources/game/          ← your CrossCode assets (git-ignored, populated by tools/sync-assets.sh)

tools/                   Automation + the macOS proof harness (see README "Under the hood").
mods/ccios-title-buttons/  Bundled CCLoader mod: native Restart/Close buttons on the title screen.
```

The macOS harness (`tools/webkit-harness`) and the iOS app are two front-ends over the **same**
host code. Develop and debug in the harness (fast, no device, no signing); ship via the app.

---

## Critical runtime invariants

These are the things that silently break the game if you get them wrong. Most were discovered the
hard way.

### Platform detection — keep the game in BROWSER mode
CrossCode picks its platform at boot:
`(window.require && typeof window.process=="object") ? DESKTOP : … : ("Unknown"!=ig.browser) ? BROWSER`.
In WebKit it resolves to **BROWSER** (assets via XHR, saves via `localStorage`, no Node `fs`).

- **Never define `window.require` globally** and **never set a custom `userAgent`** — either can
  flip detection to DESKTOP and break everything.
- A tiny no-op `window.process` shim at `documentStart` is fine (and needed for `node-webkit.html`).
- Under CCLoader, browser mode is pinned in `ccloader/js/normalize.js` (`window.isBrowser = true`).
  The `require("fs")` shim used for mod installs is provided *without* tripping DESKTOP detection.

### Audio — iOS cannot decode Ogg Vorbis (and Web Audio starts suspended)
The game ships ~1289 `.ogg` files and prefers Ogg; iOS WebKit raises a fatal "Web Audio Load
Error" (verified: WebKit `canPlayType('audio/ogg')` is `""`, and `decodeAudioData` rejects every
Ogg — so the `ffmpeg` transcode is genuinely required, not optional). The fix has **three** parts,
all required:
1. Transcode `.ogg → .m4a` (AAC) at asset-sync time (`tools/sync-assets.sh`, needs `ffmpeg`).
2. Patch `game.compiled.js` at serve time (`GameSchemeHandler.preferM4AAudio`): put M4A first **and**
   force the format selector to accept it — WebKit lies and reports the engine's M4A MIME as
   unplayable, so a plain reorder is not enough.
3. **Make Web Audio actually render on iOS.** CrossCode plays background music through HTML5
   `<audio>` (autoplays once `mediaTypesRequiringUserActionForPlayback = []`) but plays all SFX
   through Web Audio. An `AudioContext` starts **suspended** on iOS; under the `.ambient` audio
   session it stays effectively silent, so the classic symptom is *music plays but SFX don't*. Two
   things keep it rendering: the app sets `AVAudioSession` to **`.playback`** (`AudioSession.swift`),
   and `Bootstrap.webAudioUnlockJavaScript` resumes the context (nested at
   `ig.soundManager.context.context`, **not** `ig.soundManager.context`) on the first user gesture
   and on focus/visibility. The engine's own per-frame `resume()` only succeeds once the session
   permits it.

Don't remove any part. Verify after audio changes: `format.ext == "m4a"`, `ig.Sound.enabled`,
and `ig.soundManager.context.context.state === "running"`. SFX audibility itself only reproduces on
a real device (the macOS harness and the Simulator don't gate Web Audio the way iOS hardware does).

### Saves
The entire save is one `localStorage` blob under key `cc.save`, **byte-identical** to the desktop
`cc.save`. Capture/inject by hooking `Storage.prototype.setItem` (the prototype — not an instance).
Sync tooling mirrors `Documents/cc.save`; sync is optional and must stay fail-safe (no config or
unreachable server → silent no-op, never blocks boot).

### Controller
CrossCode polls `navigator.getGamepads()` every frame using the **W3C Standard Gamepad** mapping
(FACE0-3 = buttons 0-3, shoulders 4-5, triggers 6-7, SELECT 8, START 9, sticks 10-11, D-pad 12-15;
axes 0-3). The native bridge feeds `window.__ccpad`. **GameController's y-axis is inverted vs W3C**
— correct it in the bridge.

### CCLoader & mods
- Entry is `ccloader/index.html`; the game must live under `assets/`.
- Browser mode can't enumerate folders, so mods are listed in a static `mods.json` (the scheme
  handler synthesizes it, merging bundled mods with the writable overlay).
- `_resourceExists` does a HEAD and treats any non-404 as "exists" → the scheme handler **must
  return 200 for directory** requests.
- Packed `.ccmod` files can't be read in browser mode → they must be **unpacked to folders** (at
  setup time by `tools/setup-ccloader.sh`, and on-device by `ModFSBridge`/`ZipReader`).
- Mods that inject game classes (e.g. `sc.TitleScreenButtonGui`) must run in the **`prestart`**
  stage — after `game.compiled.js` defines `sc.*`. `postload`/`main` are too early/late.
- Title-screen buttons: use focus indices well clear of the game's (0–5) to avoid menu-nav
  collisions, and wrap setup + callbacks in `try/catch` so a mod error can never reach the game's
  init (which shows the `CRITICAL BUG` screen).

---

## Development workflow

1. **Edit** `Shared/CCWebHost/*` (or a mod) — the shared host is where most behavior lives.
2. **Build + prove in the harness** (fast, no device):
   ```bash
   swift build
   ./.build/debug/webkit-harness --root app/Resources/game --entry ccloader/index.html \
     --prefer-m4a --mods-overlay /tmp/cc-overlay --fps --settle 12 \
     --eval '(function(){return "platform="+ig.getPlatformName()})()'
   ```
   For a vanilla (non-CCLoader) tree use `--entry node-webkit.html`. Use `--poke` to advance past
   the splash into a New Game. Inspect state with `--eval` (use synchronous XHR inside `--eval`;
   returning a Promise is not supported).
3. **Check the INFO line**: success looks like `bootstrap=true platform=Browser jsErrors=0`. Any
   `jsErrors > 0` or a `CRITICAL BUG` string in the DOM means it's broken — fix before proceeding.
4. **Then** validate on Simulator (`make sim`) and/or device (`make device`).

When changing the audio/mods pipeline, re-run `tools/sync-assets.sh` / `tools/setup-ccloader.sh`
against a scratch tree and boot it in the harness.

---

## Verifying a change (definition of done)

- Harness boots the game with `jsErrors == 0` and no `CRITICAL BUG`.
- The specific behavior you changed is demonstrated (screenshot via `--out`, or `--eval` probe,
  or `--ls-get` for saves).
- For New-Game-path changes, boot+`--poke` several times (the title-buttons crash was intermittent).
- No game assets or personal data staged (`git status`).
- Conventional Commit message.

---

## Environment gotchas (macOS dev box)

- Stock macOS bash is **3.2** — scripts must be 3.2-compatible (no associative arrays, no
  `mapfile`). Existing scripts follow this.
- Async/background shells may not inherit Homebrew's PATH — `export PATH="/opt/homebrew/bin:$PATH"`
  for `ffmpeg`, `xcodegen`, etc.
- `timeout(1)` is **not** available by default. The harness has its own `--timeout`.
- Kill processes with a **literal numeric PID** (`kill 12345`). Name-based killers
  (`pkill`/`killall`) are disallowed.
- `simctl` can hang on rapid launch/terminate cycles — run discrete steps, not tight loops.
- `devicectl` file/install ops need the device **unlocked**; the first op after connecting is slow
  (tunnel warm-up). A live connection shows `tunnelState`, not just "paired".
- Building for device needs an Apple Team ID + signing identity (auto-detected by
  `tools/ios-build.sh`). The Simulator needs **no** signing.

---

## What can't be automated (so don't try)

- Installing full **Xcode** (App Store download).
- Signing an **Apple ID** into Xcode (Settings → Accounts is GUI-only). After that, cert/profile
  minting is CLI via `tools/ios-build.sh -allowProvisioningUpdates`.
- Enabling **Developer Mode** and **trusting** the cert on the iPhone (on-device Settings).
- **Owning CrossCode** — the user supplies their own copy.

---

## Conventions

- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`,
  `docs:`, `chore:`, `build:`, scopes like `feat(host):`). Subject lowercase, no trailing period.
- **Swift:** match the surrounding style; keep host logic platform-neutral.
- **TypeScript/JS (mods, injected JS):** no `any`; narrow `unknown`. Comment only what's non-obvious.
- **Docs:** keep `README.md` (user-facing) and this file (agent-facing) in sync when behavior or
  the install flow changes.
- **Don't** create planning/scratch markdown files in the repo.
