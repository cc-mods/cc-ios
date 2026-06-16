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
make tui         # interactive, verifiable setup (live status board; --check = read-only)
make doctor     # check the toolchain (Xcode, SDKs, xcodegen, ffmpeg, …); --fix installs brew tools
make setup      # one-shot onboarding: preflight → find game → sync+transcode assets → project
make sim        # build + run in the iOS Simulator (no signing)
make device     # build + sign + install on a connected iPhone
make harness    # boot the game in a macOS WKWebView (writes proof.png)
make help       # list all targets
```

`tools/setup-tui.sh` is a thin, interactive **front-end** over the same scripts `setup.sh` drives
(preflight, find-crosscode, sync-assets, setup-ccloader, xcodegen) — it
adds a status board and post-step verification but **must never reimplement** their logic. Keep
`setup.sh` as the headless/CI path.

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
                           SaveBridge, SaveFolder, SaveSyncBootstrap (no-op sync wiring), ControlBridge.
  project.yml              XcodeGen spec. Bundle ID / team are NOT hard-coded (passed at build).
  Resources/game/          ← your CrossCode assets (git-ignored, populated by tools/sync-assets.sh)

Shared/CCWebHost/SaveSync.swift   SaveSyncProvider protocol + SaveSync.provider registry (the
                           optional network-sync seam; nil ⇒ no-op). Filled in by cc-tailsync.
tools/                   Automation + the macOS proof harness (see README "Under the hood").
```

> **Mods & save sync now live in their own repos** (the cc-mods org), not bundled here:
> - **[cc-iosux](https://github.com/cc-mods/cc-iosux)** — cc-ios QoL tweaks: the Restart/Close
>   title buttons (was `mods/cc-ios-title-buttons` → `cc-iostitlebuttons`) plus an FPS-counter
>   toggle in CCModManager → Mod settings. Install it (and any other mod) one-click from
>   the in-game Mods tab; `setup-ccloader.sh` pre-registers the `@cc-mods/CCModDB/stable` database.
> - **[cc-tailsync](https://github.com/cc-mods/cc-tailsync)** — wireless (Tailscale) save sync:
>   the `CCTailsync` Swift package + the macOS/Windows save-servers + USB sync. cc-ios keeps only
>   **file-based save persistence** (`SaveBridge`/`SaveFolder`) and an optional `SaveSyncProvider`
>   seam that cc-tailsync's `tools/integrate-ios.sh` wires in.

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
   through Web Audio. An `AudioContext` starts **suspended** on iOS; nothing resumes it on its own,
   so the classic symptom is *music plays but SFX don't*. `Bootstrap.webAudioUnlockJavaScript`
   resumes the context (nested at `ig.soundManager.context.context`, **not**
   `ig.soundManager.context`) on the first user gesture and on focus/visibility. The engine's own
   per-frame `resume()` only starts succeeding once a gesture has unlocked audio.
   - **Audio session category: use `.ambient`, NOT `.playback`.** It is tempting to use `.playback`
     (the "correct" game category that plays through the silent switch). **Don't** — on a real
     device, activating a non-mixable `.playback` session in the host process **black-screens the
     game**. `AudioSession.activate()` runs synchronously right before `webView.load()`, so the
     host seizes an exclusive audio route exactly as the WKWebView's separate **WebContent process**
     is starting up and trying to establish its own `AudioContext` session via `mediaserverd`; the
     arbitration wedges WebContent's media/render init and the view never paints. JS logs up to
     `EXTENSIONS: []` (main-frame injection) then go silent. `.ambient` is mixable/non-interrupting,
     never seizes the route, and boots fine. Proven by toggling only the category (both builds
     vanilla): `.playback` → black, `.ambient` → title screen. The Simulator does **not** reproduce
     this (no real `mediaserverd`/hardware route). Trade-off: `.ambient` obeys the hardware mute
     switch, so audio is silenced when the ringer is on silent. **This is accepted as final.** A
     deferred `.playback` upgrade (activate `.ambient` at boot, then switch to `.playback` on the
     first user gesture) was built and device-tested: it boots fine but **still does not play
     through the silent switch**, because the WebView's audio is produced by the **WebContent
     process**, which owns its own audio session — the host app's category doesn't govern it. So
     the extra machinery bought nothing and was removed. Keep audio simple: `.ambient`, full stop.
4. **Force the Web Audio engine on (the in-game toggle is a footgun).** CrossCode's "use Web Audio"
   option (`options.useWebAudio`, stored as its own `localStorage` key — *not* in `cc.save`) selects
   the engine **once at boot**: `var m=localStorage.getItem("options.useWebAudio")!="false", m=…&&m`
   then `if(m){ig.Sound=ig.SoundWebAudio;…}`. The fallback HTML5-`<audio>` path can't preload ~1289
   sounds on iOS and **stalls the loader ~⅓ of the way** — so turning the option off soft-bricks the
   game (and survives relaunch, since it's a separate key the save sync never touches). The same
   `preferM4AAudio` serve-time patch drops the stored-setting term (`var m=true,…`) so the decision
   rests only on `ig.WebAudio.isSupported()` (always true in WebKit). This makes the toggle unable to
   break loading and **auto-heals** a device already stuck with the setting off.

Don't remove any part. Verify after audio changes: `format.ext == "m4a"`, `ig.Sound.enabled`,
and `ig.soundManager.context.context.state === "running"`. SFX audibility itself only reproduces on
a real device (the macOS harness and the Simulator don't gate Web Audio the way iOS hardware does).

### Saves
The entire save is one `localStorage` blob under key `cc.save`, **byte-identical** to the desktop
`cc.save`. Capture/inject by hooking `Storage.prototype.setItem` (the prototype — not an instance);
see `Bootstrap.swift`. cc-ios persists it to `Documents/cc.save` (`SaveBridge`) and mirrors a
Files-app `Documents/saves/` backup folder (`SaveFolder`). **This is fully standalone — no network.**

**Network (Tailscale) sync is OPTIONAL and lives in
[cc-tailsync](https://github.com/cc-mods/cc-tailsync).** cc-ios only exposes a seam: the
`SaveSyncProvider` protocol + `SaveSync.provider` registry (`Shared/CCWebHost/SaveSync.swift`). When
nothing is registered, every sync call in `GameView` no-ops, so the app builds/runs without
cc-tailsync. cc-tailsync's `tools/integrate-ios.sh` adds its `CCTailsync` SwiftPM package to
`project.yml` and replaces `app/Sources/SaveSyncBootstrap.swift` with a version that conforms
`TailscaleSyncClient` to `SaveSyncProvider` and registers it. The provider stays fail-safe (no
config / unreachable server → silent no-op, never blocks boot): it pushes on every save but **pulls
only at launch** (mtime newest-wins, sha256 short-circuit to avoid echo loops). The USB path
(`save-sync.sh`), the PC save-servers (macOS launchd + Windows Scheduled Task), and the launchd/TCC
gotcha all live in cc-tailsync now — see its docs.

### Controller
CrossCode polls `navigator.getGamepads()` every frame using the **W3C Standard Gamepad** mapping
(FACE0-3 = buttons 0-3, shoulders 4-5, triggers 6-7, SELECT 8, START 9, sticks 10-11, D-pad 12-15;
axes 0-3). The native bridge feeds `window.__ccpad`. **GameController's y-axis is inverted vs W3C**
— correct it in the bridge.

### UI overlays & external links (iOS WebView quirks)
- **You cannot draw an HTML overlay over the game on iOS.** The game renders into a
  hardware-accelerated **WebGL canvas**, and iOS WebKit composites that canvas **above all in-page
  DOM regardless of `z-index`** — even with `translateZ(0)`/`will-change` layer promotion. We chased
  this hard with the FPS counter: device logs proved the DOM element was present, `visible`, top-left,
  `z-index:2147483647`, updating at 60fps — yet it never painted in-game (it showed only during
  loading, before the canvas took over). **Fix: draw overlays natively.** The injected JS only
  *measures* and posts data (`{type:"fps"}`); `GameView` renders a `UILabel` **added as a subview of
  the `WKWebView`**, which always paints above web content. JS also reports the canvas's left edge
  (`{type:"fpslayout", leftFrac}`) so the label can sit in the black **letterbox** bar just outside
  the canvas. Position from the *canvas geometry*, **not** `safeAreaInsets.left` — that inset is
  inflated by the Dynamic Island (vertically centered on the long edge), which would shove a
  top-corner label into the game; use a small fixed corner allowance instead.
- **External links need a native path, not `window.open`.** CCModManager's "visit repository/author"
  calls `window.open(url,"_blank")` in browser mode. In a `WKWebView` that needs both a `WKUIDelegate`
  **and** a real user gesture — but the gamepad d-pad "visit" is driven through the native gamepad
  bridge (`evaluateJavaScript`), which is **not** a WebKit user gesture, so the popup is silently
  suppressed and `createWebViewWith` never fires. **Fix:** override `window.open` at documentStart
  (all frames) to post http(s) URLs to the `cccontrol` handler, which opens them via
  `UIApplication.open`. (A `WKUIDelegate`/`decidePolicyFor` fallback is wired too, but the gesture-free
  `window.open` override is what actually fixes the d-pad case.) A mod is "visitable" in the in-game
  list only if its `ccmod.json` has a `repository` (or `homepage`) field.

### CCLoader & mods
- Entry is `ccloader/index.html`; the game must live under `assets/`.
- Browser mode can't enumerate folders, so mods are listed in a static `mods.json` (the scheme
  handler synthesizes it, merging bundled mods with the writable overlay).
- `_resourceExists` does a HEAD and treats any non-404 as "exists" → the scheme handler **must
  return 200 for directory** requests.
- Packed `.ccmod` files can't be read in browser mode → they must be **unpacked to folders** (at
  setup time by `tools/setup-ccloader.sh`, and on-device by `ModFSBridge`/`ZipReader`).
- **A mod's bundled assets must be listed in its manifest's `assets` array**, or they 404 — and
  **a failed resource load at GAME INIT is FATAL** (CrossCode shows `CRITICAL BUG`, stack
  `_loadCallback`→`loadingFinished`→`onerror`). CCLoader browser-mode can't enumerate a mod's
  folder, so it only maps assets the manifest declares. Example that bit us: CCModManager ships
  `media/gui/CCModManager.png` + `media/font/ccmodmanager-icons.png` but its `ccmod.json` has no
  `assets` field → fatal crash on boot. `tools/setup-ccloader.sh` now auto-populates each mod's
  `assets` list by scanning its `assets/` dir. **Never hand-edit an unpacked mod manifest** — the
  script re-unpacks `.ccmod`s on every run and would wipe it; fix it in the script instead.
- Mods that inject game classes (e.g. `sc.TitleScreenButtonGui`) must run in the **`prestart`**
  stage — after `game.compiled.js` defines `sc.*`. `postload`/`main` are too early/late.
- Title-screen buttons: use focus indices well clear of the game's (0–5) to avoid menu-nav
  collisions, and wrap setup + callbacks in `try/catch` so a mod error can never reach the game's
  init (which shows the `CRITICAL BUG` screen).
- **The bundle can come back as vanilla** (root `node-webkit.html`, no `ccloader/`) — e.g. after a
  re-sync or across sessions. Then there's no Mods tab. Check the layout (`ccloader/index.html`
  present?) and re-run `tools/setup-ccloader.sh` to restore it, then re-install any mods one-click
  from the in-game Mods tab.
- **`sync-assets.sh` is destructive (`rsync --delete`) and resets to vanilla** — it repopulates
  `app/Resources/game` from the raw Steam tree, wiping any CCLoader overlay. So the pipeline order
  is **sync-assets → setup-ccloader**, never the reverse, and you must not re-run sync-assets after
  setup-ccloader unless you intend to start over. This bit us hard: `tools/ios-build.sh` used to
  decide "assets present?" by checking for the *vanilla* marker `Resources/game/node-webkit.html` —
  which the CCLoader layout doesn't have (the game moves to `assets/node-webkit.html`) — so **every
  device build silently re-ran sync-assets and destroyed CCLoader**, booting vanilla (no mods menu).
  The guard now also accepts `ccloader/index.html` / `assets/node-webkit.html`. When a build
  mysteriously loses mods, suspect an asset re-sync first.

### Node shimming for mods (`Bootstrap.fsShimJavaScript`)
CrossCode mods are written for the **NW.js desktop** runtime, so they `require()` Node core
modules. In BROWSER mode there is no Node, so `window.require` is a shim. Surveyed across the
bundled mods + CCLoader, the real demand is `fs`, `path`, `util`, `assert`, `events`, `nw.gui`.
What the shim provides, and the **hard limits**:

- **`fs`** — async + Node-callback styles via the native `ModFSBridge` (`writeFile/readFile/mkdir/
  readdir/stat/unlink/...`), backed by the writable `Documents/mods` overlay. **Synchronous reads**
  (`readFileSync`/`existsSync`/`statSync`) are backed by a **synchronous `XMLHttpRequest` against
  `ccgame://game/<path>`** — the scheme handler serves the bundle+overlay and responds synchronously,
  same as the game's own asset loads, so this works. `readdir(... {withFileTypes:true})` returns
  `Dirent` objects (the native side returns `{name,dir}` per entry; `statSync` reads the `X-CC-Dir`
  response header the handler sets on directories).
- **Hard ceiling — no synchronous *writes*, no sync *directory listing*.** The native bridge is
  async-only (`WKScriptMessageHandlerWithReply`), and sync XHR can't list a dir. So `writeFileSync`,
  `mkdirSync`, `readdirSync` **throw `ENOSYS` on purpose** — a clear error beats a silent wrong value.
  A mod that needs sync writes won't work on iOS; that's a WKWebView constraint, not a bug to fix.
- **Pure-JS modules** — `path` (complete: join/dirname/basename/extname/normalize/resolve/relative/
  parse/format/isAbsolute), `util` (inherits/promisify/format/inspect/type guards), `assert`, and
  `events.EventEmitter`. Cheap, safe, no I/O.
- **`http`/`https`** — mapped onto `fetch` with a minimal EventEmitter response
  (`.on("data"|"end"|"error")`). Covers "fetch a URL, read the body"; **not** streaming/sockets/keep-alive.
- **Unknown modules** (`os` is partial; `child_process`, native `.node` addons, `electron`, real
  `crypto` are **not** shimmable on iOS) return a benign `{}` **and `console.warn`** so the gap is
  visible. Returning `{}` keeps a mod that only conditionally uses the module loadable; a
  plausible-but-wrong shim would be worse than a missing one (silent corruption vs. a clear failure).

Net: this **improves the odds for well-behaved mods**, it does not *guarantee* arbitrary ones. When
adding to the shim, prefer pure-JS or sync-XHR-backed reads; never fake a sync write or return a
lie. The `dirent.isDirectory` crash (fixed in the readdir change) is the canonical "a real mod used
an fs feature we hadn't implemented" failure — expect more of that shape and add narrowly.

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

### Debugging on a physical device

- **First boot on device is SLOW** — decoding the audio tree and building caches can take
  well over 30s before the title screen appears; subsequent launches are much faster. **Don't
  mistake a slow first boot for a hang.** When capturing logs, wait 60s+ or relaunch before
  concluding it's stuck.
- **Stream the app's native logs** (our `[cc …]` / `[ccfs]` `NSLog`s) with:
  ```bash
  xcrun devicectl device process launch --console --terminate-existing \
    --device <UDID> com.example.ccios
  ```
  Note `--console` only shows the **host app** stdout, not the WebKit content process.
- **Black screen, app still alive, JS logs stop with no error** = the **WebContent process
  died** (often jetsam/OOM), *not* a JS exception (which would log `[cc JSERR]` or show
  `CRITICAL BUG`). `GameView` implements `webViewWebContentProcessDidTerminate` to log
  `[cc CRASH]` and reload.
- **Reproduce JS-level issues on the Simulator** (`make sim`) — there you get the full JS
  console via `xcrun simctl spawn booted log show` and screenshots via `xcrun simctl io booted
  screenshot`. **Caveat:** the Simulator's `AudioContext` auto-runs, so suspended-context audio
  bugs (SFX silent, decode stalls) **do not reproduce there** — only on real hardware.

---

## Verifying a change (definition of done)

- Harness boots the game with `jsErrors == 0` and no `CRITICAL BUG`.
- The specific behavior you changed is demonstrated (screenshot via `--out`, or `--eval` probe,
  or `--ls-get` for saves).
- For New-Game-path changes, boot+`--poke` several times (the title-screen button-mod crash was intermittent).
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
