# cc-ios

Run **[CrossCode](https://store.steampowered.com/app/368340/CrossCode/)** on iPhone / iPad by
wrapping the game's HTML5 runtime in a native `WKWebView` host — the iOS analog of
[**CrossAndroid**](https://gitlab.com/Namnodorel/crossandroid) by Namnodorel.

> ### ⚠️ You must own CrossCode. This repo does not contain the game.
>
> cc-ios is **only the wrapper**. It ships **zero** game code or assets. You supply your own
> legally-owned copy of CrossCode (Steam / GOG / itch.io); the build tooling copies *your* files
> into the app locally. Game assets are git-ignored and never committed or distributed here.
>
> This is an unofficial fan project, **not affiliated with or endorsed by Radical Fish Games**.
> It is **sideload-only** (your own Apple signing) — not the App Store. See
> [Legal & distribution](#legal--distribution).

> **Status: 🟢 Running on a physical iPhone.** Boots cleanly (0 JS errors, live WebGL render
> loop), audio works, hardware controllers work, saves persist and sync with the desktop copy,
> and **CCLoader mods load** (including the in-game one-click mod manager). See
> [Installation](#installation) to build your own copy.

## What works

| Feature | State | Notes |
|---|---|---|
| 🎮 Boots & runs the full game | ✅ | iOS Simulator **and** physical iPhone; live render loop |
| 🔊 Audio | ✅ | Ogg→M4A transcode + serve-time format patch (iOS can't decode Ogg) |
| 🕹️ Hardware controllers | ✅ | MFi / Xbox / DualShock via GameController → JS gamepad shim |
| 💾 Saves persist | ✅ | `localStorage["cc.save"]`, byte-identical to the desktop save |
| 🔁 Save sync with PC | ✅ | USB (`devicectl`) or wireless (Tailscale) — Steam Cloud spans your PCs |
| 🧩 CCLoader mods | ✅ | Mods tab in-game; native Restart/Close title buttons; one-click mod manager |
| 📈 FPS overlay | ✅ | Top-right, color-coded |
| 🎨 Custom app icon | ✅ | Bring your own (`app/Resources/Assets.xcassets`) |

---

## How we know it works

The riskiest parts of this port — *will the desktop game run in WebKit, does the
synchronous-filesystem problem block it, and will audio work?* — are **validated against the real
game binary**, both with a macOS WKWebView harness (`tools/webkit-harness`, the same WebKit APIs
as iOS) and by **running on device**.

| Result | Evidence |
|---|---|
| ✅ Runs on iPhone + Simulator | App launches, renders the title screen, **render loop is live** (successive frames differ) |
| ✅ Boots in WebKit | `ig.ready === true` ~5s after load; WebGL canvas active |
| ✅ No filesystem bridge needed to boot | Game selects its **BROWSER** platform path → assets via XHR, saves via `localStorage` |
| ✅ Audio works on iOS | Ogg→M4A transcode + format patch → `format.ext == "m4a"`, `Sound.enabled`, AudioContext `running` |
| ✅ Saves are cross-platform | Desktop `cc.save` is byte-identical to iOS `localStorage["cc.save"]`; loads with `slotCount: 2` |
| ✅ Mods load | CCLoader boots the game; `mods.json` mods initialize; one-click install proven end-to-end |
| ✅ Clean boot | **0** JavaScript errors, **0** fatal asset loads |
| ✅ Shared code path | iOS app and macOS harness build from the **same** `Shared/CCWebHost` sources |


### Why the "synchronous `fs`" risk turned out to be a non‑issue

CrossCode has a built‑in platform abstraction. Its detection logic (verified in
`assets/js/game.compiled.js`) is:

```js
ig.platform = (window.require && typeof window.process === "object") ? DESKTOP
            : window.nwf                                            ? WIIU
            : ("Android" === ig.dataOS || "iOS" === ig.dataOS)      ? MOBILE
            : ("Unknown" !== ig.browser)                            ? BROWSER
            :                                                         UNKNOWN;
```

Inside WebKit, `window.require` is undefined and `navigator.vendor` contains `"Apple"`, so the
game resolves to **`BROWSER`**. Every `fs` / `nw.gui` call in the binary is gated behind
`ig.platform === DESKTOP`, so the browser path:

- loads all assets via jQuery `.ajax` / XHR against **relative paths** → fully satisfied by a
  `WKURLSchemeHandler`;
- reads/writes saves through **`localStorage`** → natively persisted by WebKit, on device;
- never calls `readFileSync` / `writeFileSync` / `readdirSync` (literally **0** occurrences).

The only NW.js touch‑point is parse‑time: `node-webkit.html` calls `window.process.once(...)`. We
inject a tiny no‑op `window.process` shim at `documentStart` (but deliberately **not**
`window.require`, which would flip detection to DESKTOP). That's the entire "native bridge".

> Net effect: the original "🔴 highest friction: synchronous filesystem bridge" risk is
> **eliminated** for this build. No async‑bridge gymnastics, no `fs` shim, no CCLoader patching
> required to boot.

### The real friction: audio (Ogg Vorbis)

The one substantive iOS problem is audio. CrossCode ships **1289 Ogg Vorbis** files and its engine
prefers Ogg (`ig.Sound.use = [OGG, MP3]`). iOS/WebKit can't decode Ogg via Web Audio — it raises a
fatal *"Web Audio Load Error"* that crashes the game on boot. Two‑part fix, both automated:

1. **Transcode** the media tree to **M4A (AAC)** — natively decodable on all Apple platforms —
   via `ffmpeg` in `tools/sync-assets.sh` (the `.ogg` originals are dropped; bundle 835 MB → 751 MB).
2. **Patch `game.compiled.js` at serve time** (`GameSchemeHandler.preferM4AAudio`): put `M4A` first
   in the format list *and* force the selector to accept it (WebKit reports the engine's exact M4A
   MIME string as unplayable, so a plain reorder isn't enough). The engine strips each sound's
   extension and re‑appends `format.ext`, so requests become `.m4a` and resolve cleanly.

Verified after the fix: `format.ext == "m4a"`, `ig.Sound.enabled == true`, AudioContext `running`,
**0** errors.

---

## Architecture

```
┌────────────────────────── iOS app (app/) ──────────────────────────┐
│  SwiftUI App  →  GameView (WKWebView)  + AudioSession, Controller-,  │
│                     │                    Save-, Control-, SyncBridges │
│        ┌────────────┴───────────── Shared/CCWebHost ──────────────┐  │
│        │  GameWebHost       build WKWebViewConfiguration           │  │
│        │  GameSchemeHandler  ccgame:// → files (+Range, audio,     │  │
│        │                     mods overlay, mods.json synthesis)    │  │
│        │  Bootstrap         injected JS: NW.js neutralization,     │  │
│        │                     console bridge, save hook, gamepad    │  │
│        │                     shim, fs/require shim, FPS overlay    │  │
│        │  ModFSBridge       native async fs for one-click installs │  │
│        │  ZipReader         unpack .ccmod packages on device       │  │
│        └────────────────────────────────────────────────────────┘   │
│                     │                                                │
│   Bundled assets (app/Resources/game, git‑ignored) ── localStorage   │
│                     ┆ optional, fail-safe                            │
│   Documents/cc.save  ┄┄►  USB / Tailscale save sync (PC ↔ iOS)       │
└──────────────────────────────────────────────────────────────────────┘
            ▲ same CCWebHost sources ▼
┌──────────────────── macOS proof harness (tools/webkit-harness) ─────┐
│  AppKit window + WKWebView, boots real assets, logs console,         │
│  polls ig.ready, writes a screenshot. Runs without Xcode/iOS.        │
└──────────────────────────────────────────────────────────────────────┘
```

The app **boots fully standalone**: assets are baked into the `.app` and saves live in on-device
`localStorage` — no companion server, no network dependency. Save sync is **optional and
fail-safe** (if unconfigured or unreachable it is a silent no-op and never blocks boot).

### Android → iOS mapping

| CrossAndroid (Android) | cc-ios (iOS) | Status |
|---|---|---|
| `WebView` | `WKWebView` (separate content process, JIT + WebGL) | ✅ working |
| `WebViewClient.shouldInterceptRequest` | `WKURLSchemeHandler` on `ccgame://` streaming from the sandbox | ✅ working |
| `addJavascriptInterface` (**sync**) | *Not needed* — BROWSER path uses XHR + `localStorage` | ✅ avoided |
| Copy folder to `Android/data/...` | Assets bundled into the `.app` at build time | ✅ working |
| `InputDevice` controller detection | GameController framework (MFi / Xbox / DualShock) | ✅ working |
| Virtual on‑screen controller | **Dropped** (hardware controllers + keyboard only) | ⚪ out of scope |
| APK sideload | Free 7‑day dev cert / AltStore / SideStore | ✅ working |

---

## Repository layout

```
cc-ios/
├── README.md
├── LICENSE                       MIT (this wrapper's own code only)
├── Package.swift                 SwiftPM: CCWebHost library + macOS harness
├── Shared/CCWebHost/             Cross-platform WebKit host (iOS + macOS)
│   ├── GameSchemeHandler.swift   Custom-scheme file server (+Range, audio patch, mods overlay)
│   ├── Bootstrap.swift           Injected JS: NW.js neutralization, console/save/gamepad/fs/FPS
│   ├── GameWebHost.swift         WKWebViewConfiguration factory + entry URL resolution
│   ├── ModFSBridge.swift         Native async fs bridge for one-click mod installs
│   └── ZipReader.swift           Minimal ZIP/deflate reader to unpack .ccmod packages
├── app/                          iOS application
│   ├── project.yml               XcodeGen spec (generates cc-ios.xcodeproj)
│   ├── Sources/                  CCIOSApp, GameView, AudioSession, ControllerBridge,
│   │                             SaveBridge, SaveSyncClient, ControlBridge
│   ├── Resources/Assets.xcassets App icon (bring your own)
│   └── Resources/game/           ← your CrossCode assets (git-ignored, build-time copy)
├── mods/
│   └── ccios-title-buttons/      CCLoader mod: native Restart/Close buttons on the title screen
└── tools/
    ├── webkit-harness/           macOS WKWebView proof harness (SwiftPM executable)
    ├── sync-assets.sh            Copy assets into app/Resources/game + Ogg→M4A transcode
    ├── setup-ccloader.sh         Overlay CCLoader + mods, regenerate mods.json
    ├── ios-build.sh              One-shot: build → sign → install → launch on device
    ├── save-sync.sh              USB save sync (xcrun devicectl)
    └── save-server.py            Optional wireless save hub (Tailscale)
```

Game assets, the generated `.xcodeproj`, and any local path config are **git-ignored**. Nothing
copyrighted or personal is committed.

---

## Installation

> **Time:** ~30–60 min the first time (most of it is a one-time Xcode/audio-transcode wait).
> **You need a Mac.** Building and signing an iOS app requires macOS + Xcode.

### Prerequisites

| Requirement | Why / how |
|---|---|
| **macOS** with **full Xcode** | Not just Command Line Tools. Install from the App Store, launch once to accept the license, then `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. |
| **iOS platform component** | Xcode → Settings → Components → install **iOS** (and the Simulator runtime). |
| **Homebrew tools** | `brew install xcodegen ffmpeg` — `xcodegen` generates the Xcode project; `ffmpeg` transcodes audio to an iOS-decodable format. |
| **Your own copy of CrossCode** | Steam / GOG / itch.io. On a Steam macOS install the assets are at `…/Steam/steamapps/common/CrossCode/CrossCode.app/Contents/Resources/app.nw/assets`. |
| **An Apple ID** | A **free** Apple ID works for personal sideloading (with caveats — see [Apple Developer & signing](#apple-developer--signing)). A paid Apple Developer account ($99/yr) removes the 7-day expiry. *(Device only — the Simulator needs no signing.)* |
| **An iPhone/iPad** *(for device install)* | iOS 16+, **Developer Mode** enabled, and the Mac **trusted**. |

### 1. Get the code

```bash
git clone https://github.com/Yoyokrazy/cc-ios.git
cd cc-ios
```

### 2. Point the tooling at *your* CrossCode files

Tell the build where your game's `assets` folder lives (the directory that contains
`node-webkit.html`). First match wins: `$CCIOS_ASSET_ROOT` → `asset-root.local` → the default
Steam path.

```bash
echo "/path/to/CrossCode/.../app.nw/assets" > tools/webkit-harness/asset-root.local
# or, per-shell:  export CCIOS_ASSET_ROOT="/path/to/.../app.nw/assets"
```

### 3. (Optional but recommended) Prove it boots — no Xcode, no device

This runs the real game in a macOS WKWebView using the **same** host code the iPhone build uses.
Fastest way to confirm your asset path is correct before touching Xcode.

```bash
swift run webkit-harness --settle 8 --out proof.png
# Opens a window, boots the game, writes proof.png, exits 0 on ig.ready.
```

### 4. Copy your assets into the app (and fix audio)

```bash
tools/sync-assets.sh
```

This copies your `assets/` into the git-ignored `app/Resources/game/`, then transcodes all
**1289 Ogg Vorbis** files to **M4A/AAC** (iOS WebKit can't decode Ogg — this prevents a fatal
audio crash). Expect this to take a few minutes the first time; it parallelizes across cores.

### 5. (Optional) Add CCLoader + mods

Skip this for a vanilla game. To enable the in-game **Mods** menu, the one-click mod manager, and
the native Restart/Close title buttons:

```bash
tools/setup-ccloader.sh                              # download CCLoader, restructure for mods
tools/setup-ccloader.sh --add-mod mods/ccios-title-buttons   # add this repo's title-buttons mod
```

`setup-ccloader.sh` restructures `app/Resources/game/` into the CCLoader layout, pins browser
mode, unpacks any packed `.ccmod` files (browser mode can't read inside packed mods), and
regenerates `mods.json`. The app auto-detects `ccloader/index.html` and boots through it. See
[Mods](#mods-ccloader) for details.

### 6a. Run in the iOS Simulator (no signing needed — easiest first run)

```bash
cd app && xcodegen generate && cd ..
xcodebuild -project app/cc-ios.xcodeproj -scheme cc-ios \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath build build
xcrun simctl boot 'iPhone 16' 2>/dev/null; open -a Simulator
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/cc-ios.app
xcrun simctl launch booted com.example.ccios
# In the Simulator, rotate to landscape: ⌘→
```

*(Pick any installed Simulator device name; `xcrun simctl list devices` shows them.)*

### 6b. Build, sign, and run on a connected iPhone

Plug in the iPhone, unlock it, and trust the Mac. Then:

```bash
tools/ios-build.sh
```

That one script regenerates the project, auto-detects your **device UDID** and **signing team**,
builds with automatic provisioning (`-allowProvisioningUpdates`), installs via
`xcrun devicectl`, and launches. Override anything:

```bash
tools/ios-build.sh --bundle-id com.yourname.ccios --team ABCDE12345 --device <UDID> --no-launch
```

If signing isn't set up yet, or the first launch fails with a trust prompt, see the next section.

---

## Apple Developer & signing

Sideloading an app you build yourself requires code-signing it with an Apple account. This is the
fiddliest part of the whole process, so here's the complete picture.

### Free Apple ID vs paid Developer account

| | **Free Apple ID** | **Paid ($99/yr)** |
|---|---|---|
| Cost | Free | $99/year |
| Signing cert lifetime | **7 days** — app stops launching after a week, must re-sign/reinstall | **1 year** |
| App IDs | 10 per 7 days | Effectively unlimited |
| Apps sideloaded at once | 3 | Unlimited |
| Good for | Trying it out, occasional play | Daily driver, no weekly re-install |

For most people the **free** tier is fine — you just re-run `tools/ios-build.sh` (or refresh via
AltStore/SideStore, below) once a week.

### One-time setup

1. **Add your Apple ID to Xcode:** Xcode → Settings → Accounts → **+** → Apple ID. This creates a
   free "Personal Team."
2. **Pick a unique bundle ID.** The default `com.example.ccios` may already be taken on Apple's
   servers (bundle IDs are globally unique per account). Use your own, e.g.
   `com.yourname.ccios`, and pass it through every build:
   ```bash
   export CCIOS_BUNDLE_ID=com.yourname.ccios
   ```
3. **Mint the certificate.** The easiest one-time way is to open `app/cc-ios.xcodeproj` in Xcode →
   select the **cc-ios** target → **Signing & Capabilities** → check *Automatically manage
   signing* → choose your **Personal Team**. Xcode creates the development certificate. After
   that, `tools/ios-build.sh` works entirely from the CLI.

### On the iPhone

1. **Enable Developer Mode:** Settings → Privacy & Security → Developer Mode → on → reboot.
   *(Only appears once the device has been connected to Xcode at least once.)*
2. **Trust your developer certificate** (required on first launch of a free-signed app): Settings →
   General → **VPN & Device Management** → tap your developer account → **Trust**. Then relaunch
   the app.
3. **Trust the computer** if prompted when you plug in (USB).

### Re-signing without a Mac (free tier)

To avoid the weekly cable dance, **[AltStore](https://altstore.io)** or
**[SideStore](https://sidestore.io)** can refresh the signature over Wi-Fi from the phone itself.
Build the `.ipa` once, then let AltStore manage renewals.

### Signing troubleshooting

| Symptom | Fix |
|---|---|
| `No signing certificate "iOS Development" found` | Add your Apple ID in Xcode → Accounts; build once in Xcode to mint the cert. |
| `Failed to register bundle identifier` | The bundle ID is taken — choose a different `CCIOS_BUNDLE_ID`. |
| `Unable to install … device not connected` | Unlock the phone; trust the Mac; confirm `xcrun devicectl list devices` shows it as connected. |
| App installs but won't open ("Untrusted Developer") | Trust the cert on the device (see above). |
| App launched fine, then stops opening after ~a week | Free cert expired — re-run `tools/ios-build.sh`, or use AltStore/SideStore. |
| `full Xcode not selected` | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |

---

## Background: how CrossCode runs

CrossCode is built on the **Impact** JavaScript engine and ships on desktop inside **NW.js**
(Chromium + Node.js). It is fundamentally a WebGL/Canvas web game; on desktop it uses Node `fs`
for assets and saves, but — as shown above — it also has first‑class **BROWSER** and **MOBILE**
code paths that need neither Node nor a native filesystem bridge. The desktop entry point is
`assets/node-webkit.html`; mods load through
**[CCLoader](https://github.com/CCDirectLink/CCLoader)** (not required to boot the base game).

## How CrossAndroid works (reference)

CrossAndroid is a thin native wrapper around the Android system WebView: it serves the game's
files through `shouldInterceptRequest`, bridges JS↔Kotlin with `addJavascriptInterface`, and lets
the user import the `CrossCode` folder into the app's data dir. cc-ios mirrors the file‑serving
idea with `WKURLSchemeHandler`, but — because the iPhone build runs in BROWSER mode — it does
**not** need the synchronous JS bridge that is central to CrossAndroid.

---

## Roadmap

- [x] **M0 — Spike:** `WKWebView` + `WKURLSchemeHandler` serving content from the sandbox; confirm
      WebGL renders. *(Proven in the macOS harness.)*
- [x] **M1 — Boot CrossCode:** serve the real asset tree; reach `ig.ready` with a live canvas;
      resolve the sync-`fs` question. *(Proven: BROWSER mode, no `fs`, 0 errors.)*
- [x] **M1b — Run in the iOS Simulator:** build, install, launch; title screen renders with a live
      render loop; audio fixed (Ogg→M4A). *(Done.)*
- [x] **M1c — On a physical iPhone:** Developer Mode on, signed build installed via
      `tools/ios-build.sh`, launches and runs. *(Done — confirmed on device.)*
- [x] **M2 — Input:** hardware GameController (MFi / Xbox / DualShock) + keyboard. *(Done — confirmed
      on device. No on-screen virtual controller — intentionally out of scope.)*
- [x] **M3 — Saves:** `localStorage["cc.save"]` persists across launches; desktop save loads on iOS;
      USB + wireless (Tailscale) sync. *(Done; see [save sync](#saves--sync-steam--ios).)*
- [x] **Mods:** CCLoader boots the game; in-game Mods menu; one-click mod manager; native
      Restart/Close title buttons. *(Done; see [Mods](#mods-ccloader).)*
- [ ] **M4 — Polish:** safe-area / notch insets, audio-focus edge cases, in-app save import/export
      UI, performance passes. *(Lifecycle/audio-session wiring already in `GameView`/`AudioSession`;
      FPS overlay shipped.)*

---

## Controller

Plug in or pair any MFi / Xbox / PlayStation controller (Settings → Bluetooth). The app uses
Apple's **GameController** framework and feeds a small JS gamepad shim (`window.__ccpad`) that
mirrors the **W3C Standard Gamepad** mapping CrossCode polls every frame — so face buttons,
shoulders, triggers, sticks, and the D-pad all work. The native y-axis (inverted vs. W3C) is
corrected in the bridge.

> CrossCode keys its on-screen button *hints* off the last input device it saw. On a fresh boot it
> may show keyboard/mouse glyphs until you press a controller button; input still works regardless.

## Mods (CCLoader)

Run `tools/setup-ccloader.sh` (Installation step 5) to enable
**[CCLoader](https://github.com/CCDirectLink/CCLoader)**. Once set up, the game's main menu gets a
**Mods** tab, and this build adds:

- **One-click mod manager** — [CCModManager](https://github.com/CCDirectLink/CCModManager) is
  bundled and works on-device. Browse the catalog and install with a tap; the native
  `ModFSBridge` writes the `.ccmod` into a writable `Documents/mods` overlay and `ZipReader`
  unpacks it (browser mode can't read packed mods directly). Restart to load.
- **Native title-screen buttons** — a small bundled mod (`mods/ccios-title-buttons`) injects
  **Restart Game** and **Close Game** buttons below *Options* on the title screen.

How it works on iOS: CCLoader normally enumerates the `mods/` folder via Node `fs`, which the
BROWSER path doesn't have. cc-ios pins CCLoader to browser mode, serves a synthesized `mods.json`
(merging bundled mods with anything installed into the `Documents/mods` overlay), returns HTTP 200
for directory probes, and provides a `require("fs")` shim (callback **and** promises style) backed
by the native bridge for installs.

## FPS overlay

A color-coded frames-per-second readout sits in the **top-right** corner (green ≥ 55, amber ≥ 30,
red below). It's injected by the host (`Bootstrap.fpsOverlayJavaScript`) into whichever frame holds
the game canvas, so it works whether the game runs directly or inside CCLoader.

---

## Saves & sync (Steam ↔ iOS)

CrossCode stores its entire save in one blob under the key `cc.save` — and the **browser/iOS
`localStorage["cc.save"]` value is byte-for-byte identical to the desktop save file**
(`~/Library/Application Support/CrossCode/Default/cc.save` on macOS; both are
`{"slots":["[-!_0_!-]…AES…"]}`). Verified by loading a real desktop save into the iOS WebKit store:
the game reported `hasSlots: true, slotCount: 2`.

Because the blob is interchangeable, you can move a save between your PC and iPhone two ways:

- **USB** — `tools/save-sync.sh` copies `cc.save` between the desktop file and the app container
  (`Documents/cc.save`) via `xcrun devicectl`, newest-wins:
  ```bash
  tools/save-sync.sh              # sync whichever side is newer
  tools/save-sync.sh --to-phone   # force desktop → phone
  tools/save-sync.sh --from-phone # force phone → desktop
  ```
- **Wireless (Tailscale)** — run `tools/save-server.py` on your PC (it mirrors the desktop
  `cc.save`), then drop a `Documents/cc-sync.json` on the phone pointing at it. The in-app
  `SaveSyncClient` pulls a newer save at launch and pushes on change. It is **fully fail-safe**:
  no config or unreachable server → silent no-op, never blocks the game.
  ```json
  { "url": "http://100.x.y.z:8765", "token": "optional-bearer" }
  ```

Notes:

- **PC ↔ PC** is automatic via **Steam Cloud** (`platformstosync2 = -1`); the sync above bridges iOS
  into that same save.
- **iOS can't join Steam Cloud** directly (no Steam client) — hence the USB / Tailscale paths.
- The harness can round-trip saves too: `webkit-harness --ls-key cc.save --ls-set-file <save>` to
  import, `--ls-get` / `--ls-clear` to read/clear.

---

## Legal & distribution

**cc-ios is an unofficial fan-made wrapper. It is not affiliated with, authorized, or endorsed by
Radical Fish Games. It contains no CrossCode code or assets.** You must own a legal copy of
CrossCode to use it; you are responsible for complying with the game's license.

- **No game assets are distributed here.** You supply your own CrossCode files; they are
  git-ignored and only copied locally at build time.
- **App Store distribution is out of scope.** Importing/executing externally supplied game code
  conflicts with App Store Review Guideline **§4.7**, and the IP isn't ours to ship. The target is
  **personal sideloading**, mirroring CrossAndroid's APK model — for your own legally-owned copy.
- **Free Apple ID caveat:** personal-team signing certificates expire after **7 days**, so the app
  must be re-signed/re-installed weekly. For an on-device refresh without a Mac, use
  **[AltStore](https://altstore.io)** / **[SideStore](https://sidestore.io)**; for 1-year certs, a
  paid Apple Developer account.
- This wrapper's **own source code** is MIT licensed (see [`LICENSE`](LICENSE)). CrossCode,
  CCLoader, CCModManager, and CrossAndroid are the property of their respective owners.

## Credits

- **[CrossAndroid](https://gitlab.com/Namnodorel/crossandroid)** by **Namnodorel** — the reference
  implementation and proof that the WebView‑wrapper approach works.
- **[CrossCode](https://www.cross-code.com/)** by **Radical Fish Games**.
- **[CCLoader](https://github.com/CCDirectLink/CCLoader)** and
  **[CCModManager](https://github.com/CCDirectLink/CCModManager)** by the CCDirectLink community.
