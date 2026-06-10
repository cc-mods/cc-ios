# cc-ios

An experimental effort to run **[CrossCode](https://store.steampowered.com/app/368340/CrossCode/)**
on iOS / iPadOS, by wrapping the game's HTML5 runtime in a native `WKWebView` host —
the iOS analog of [**CrossAndroid**](https://gitlab.com/Namnodorel/crossandroid) by Namnodorel.

> **Status:** 🔬 Research / initiation. No app code yet — this repo currently captures the
> architecture analysis and the porting plan. See [Roadmap](#roadmap).

> **This repo never contains CrossCode game assets.** You bring your own legally‑owned copy of
> the game files. Distribution is **sideload‑only** (personal dev signing / AltStore), not the
> App Store — see [Legal & distribution](#legal--distribution).

---

## Background: how CrossCode runs

CrossCode is built on the **Impact** JavaScript engine and ships inside **NW.js**
(Chromium + Node.js). It is, fundamentally, a WebGL/Canvas web game whose only hard native
dependency is **Node.js filesystem access** (`require`, `fs`) used to load assets and read/write
saves. The desktop entry point is `assets/node-webkit.html`; mods load through
**[CCLoader](https://github.com/CCDirectLink/CCLoader)**.

Because it's "just a web app + a filesystem bridge", it can be hosted by any embedded browser
that (a) renders WebGL and (b) can serve the game's files and shim the Node APIs. That is exactly
what CrossAndroid does, and what this project aims to do on iOS.

## How CrossAndroid works (reference architecture)

CrossAndroid is a thin **native wrapper around the Android system WebView** — _not_ a bundled
browser. The essential moving parts:

| Concern | Android mechanism |
|---|---|
| Render the game | `android.webkit.WebView` loading `node-webkit.html` (or the CCLoader entry HTML) |
| Serve game files | `WebViewClient.shouldInterceptRequest` + a virtual URL; files live on disk at `Android/data/de.radicalfishgames.crosscode/files/CrossCode` |
| JS ↔ native bridge | `WebView.addJavascriptInterface(obj, "CrossAndroid")` — **synchronous** calls from JS into Kotlin |
| Bootstrap | Requires **CCLoader**; without it, falls back to calling `doStartCrossCodePlz()` after page load |
| Game files onto device | User copies the `CrossCode` folder into the app's external files dir (guided setup) |
| Extras | Virtual on‑screen controller overlay, native controller detection (`InputDevice`), haptics, and Save‑String **import/export** (saves move as opaque text blobs, no direct file sharing) |

Key source files studied: `GameActivity.kt` (lifecycle, controller detection, feature wiring),
`GameWrapper.kt` (WebView config + JS bridge + load flow), and the `features/` package
(virtual controller, layout switching, import/export, haptics).

## iOS port: target architecture

The model maps cleanly onto iOS's system WebKit. Nothing here requires a custom browser engine
(which iOS forbids anyway).

| CrossAndroid (Android) | cc-ios target (iOS) | Risk |
|---|---|---|
| `WebView` | **`WKWebView`** — runs in a separate content process **with JIT** + WebGL | 🟢 low |
| `shouldInterceptRequest` | **`WKURLSchemeHandler`** registered on a custom scheme (e.g. `crosscode://`) to stream files from the app sandbox | 🟢 low |
| `addJavascriptInterface` (**sync**) | **`WKScriptMessageHandler`** / `WKScriptMessageHandlerWithReply` (**async only**) + `evaluateJavaScript` | 🔴 **highest friction** |
| `InputDevice` controller detection | **GameController** framework (MFi / Xbox / DualShock) | 🟢 low |
| On‑screen controls overlay | UIKit/SwiftUI overlay above the web view, forwarding synthetic input via JS | 🟡 medium |
| Copy to `Android/data/...` | **Files app import** / iTunes File Sharing (`UIFileSharingEnabled`) into the app sandbox | 🟡 UX friction |
| APK sideload | Free 7‑day dev cert / AltStore / TestFlight (no public store) | 🟡 distribution |

### The core technical risk: synchronous filesystem bridge

Android's `addJavascriptInterface` returns values **synchronously**, so a JS `fs`‑style shim can
do `const data = CrossAndroid.readFileSync(path)`. iOS `WKScriptMessageHandler` is
**asynchronous only** — JS cannot block on a native reply. CCLoader / the game may expect
synchronous reads in places.

Mitigation strategies (to be validated, likely in combination):
1. **Serve everything over `WKURLSchemeHandler`.** Asset loads already go through the network
   layer (XHR/`fetch`), which the scheme handler satisfies — no sync bridge needed for reads.
2. **Preload a manifest / hot files** into JS memory before boot so the few truly‑synchronous
   `fs` calls hit an in‑memory cache.
3. **Shim `fs` to async where the game tolerates it**, patching CCLoader as needed.
4. Saves (writes) can use the async message bridge — mirroring CrossAndroid's Save‑String flow
   if direct writes prove awkward.

Proving out (1)+(2) on a real device is the first milestone that determines overall feasibility.

## Roadmap

- [ ] **M0 — Spike:** minimal Xcode app, `WKWebView` + `WKURLSchemeHandler` serving a trivial
      WebGL page from the sandbox. Confirm JIT/WebGL/perf on device.
- [ ] **M1 — Boot CrossCode:** serve a real `CrossCode` folder via the scheme handler; get
      `node-webkit.html` + CCLoader to start. Resolve the sync‑`fs` question.
- [ ] **M2 — Input:** GameController support + an on‑screen touch overlay.
- [ ] **M3 — Saves:** read/write or Save‑String import/export; Files‑app import flow for game data.
- [ ] **M4 — Polish:** fullscreen/safe‑area/notch handling, audio focus, lifecycle (pause/resume),
      performance passes.

## Prerequisites (dev)

- macOS + **Xcode** (this is being initiated on macOS).
- An Apple ID for free 7‑day signing, or a paid Apple Developer account for longer‑lived builds.
- A **legally‑owned copy of CrossCode** (Steam / GOG / itch.io) to source the game files from,
  plus [CCLoader](https://github.com/CCDirectLink/CCLoader) — exactly as CrossAndroid requires.

## Legal & distribution

- **No game assets are distributed here.** You supply your own CrossCode files.
- Apple App Store distribution is effectively out of scope: importing/executing externally
  supplied game code conflicts with App Store Review Guideline **§4.7** expectations, and the IP
  isn't ours to ship. Target is **personal sideloading**, mirroring CrossAndroid's APK model.
- This wrapper's **own source code** is MIT licensed (see [`LICENSE`](LICENSE)). CrossCode,
  CCLoader, and CrossAndroid are the property of their respective owners.

## Credits

- **[CrossAndroid](https://gitlab.com/Namnodorel/crossandroid)** by **Namnodorel** — the reference
  implementation and proof that the WebView‑wrapper approach works.
- **[CrossCode](https://www.cross-code.com/)** by **Radical Fish Games**.
- **[CCLoader](https://github.com/CCDirectLink/CCLoader)** by the CCDirectLink community.
