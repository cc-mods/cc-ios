# cc-ios

Run **[CrossCode](https://store.steampowered.com/app/368340/CrossCode/)** on iPhone / iPad by
wrapping the game's HTML5 runtime in a native `WKWebView` — the iOS analog of
[**CrossAndroid**](https://gitlab.com/Namnodorel/crossandroid) by Namnodorel.

> ### ⚠️ You must own CrossCode. This repo does not contain the game.
>
> cc-ios is **only the wrapper** — it ships **zero** game code or assets. You supply your own
> legally-owned copy (Steam / GOG / itch.io); the tooling copies *your* files into the app locally.
> This is an unofficial fan project, **not affiliated with or endorsed by Radical Fish Games**, and
> is **sideload-only** (your own Apple signing) — not the App Store.

**Status: running on a physical iPhone** — boots cleanly, audio works, controllers work, saves
persist and sync with the desktop copy, and CCLoader mods load.

## Features

| Feature | Notes |
|---|---|
| 🎮 Runs the full game | iOS Simulator **and** physical iPhone |
| 🔊 Audio | auto-transcodes Ogg→M4A at setup (iOS/WebKit can't decode Ogg) |
| 🕹️ Hardware controllers | MFi / Xbox / PlayStation, via Apple's GameController framework |
| 💾 Saves | persist on-device; byte-identical to the desktop `cc.save`; Files-app backup folder |
| 🔁 PC save sync | optional, via **[cc-tailsync](https://github.com/cc-mods/cc-tailsync)** (USB or Tailscale; Steam Cloud spans your PCs) |
| 🧩 CCLoader mods | in-game **Mods** tab, one-click mod manager (the [cc-mods](https://github.com/cc-mods) suite is pre-registered) |
| 📈 FPS overlay | color-coded, top-right |

There's no on-screen virtual controller (hardware controllers + keyboard only), and App Store
distribution is out of scope — this is for sideloading your own legally-owned copy.

## Install

> **You need a Mac** with **full Xcode** (not just Command Line Tools). Building/signing an iOS app
> is macOS-only. First run takes ~30–60 min, mostly a one-time audio transcode + Xcode build.
> *(Want Windows? See [issue #1](https://github.com/Yoyokrazy/cc-ios/issues/1).)*

```bash
git clone https://github.com/Yoyokrazy/cc-ios.git && cd cc-ios
make tui          # guided, verifiable setup (live status board)
make sim          # build + run in the iOS Simulator (no signing needed)
```

`make tui` checks your toolchain, **auto-detects your CrossCode install** (Steam / GOG / itch),
copies the assets in and transcodes audio, optionally installs CCLoader + mods, and generates the
Xcode project. Prefer plain/scriptable output? Use `make setup` (same pipeline, no UI;
`make setup ARGS="--yes --with-mods --fix --sim"` does everything unattended). `make doctor` checks
your environment; `make help` lists all targets.

### What you need

| Requirement | How |
|---|---|
| **macOS + full Xcode** | Install from the App Store, launch once, then `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. |
| **iOS platform + Simulator** | Xcode → Settings → Components, or `xcodebuild -downloadPlatform iOS`. |
| **xcodegen + ffmpeg** | `brew install xcodegen ffmpeg` — or let `make setup ARGS=--fix` do it. |
| **Your copy of CrossCode** | Steam / GOG / itch. Auto-detected; otherwise `echo "/path/to/CrossCode/.../assets" > tools/webkit-harness/asset-root.local`. |
| **Apple ID + iPhone** *(device only)* | Free tier works; see signing below. The Simulator needs no signing. |

### Run on a physical iPhone

```bash
make device       # auto-detects your device + signing team, builds, signs, installs, launches
```

One-time signing setup:

1. **Add your Apple ID to Xcode** (Settings → Accounts → **+**) — creates a free "Personal Team".
2. **Pick a unique bundle ID** (the default may be taken): `export CCIOS_BUNDLE_ID=com.yourname.ccios`.
3. On the **iPhone**: enable **Developer Mode** (Settings → Privacy & Security → Developer Mode →
   reboot), then on first launch **trust the cert** (Settings → General → VPN & Device Management →
   your account → Trust).

**Free Apple ID caveat:** personal-team certs expire after **7 days** — re-run `make device`
weekly, or use **[AltStore](https://altstore.io)** / **[SideStore](https://sidestore.io)** to
refresh over Wi-Fi.

| Trouble | Fix |
|---|---|
| `Failed to register bundle identifier` | The ID is taken — set a different `CCIOS_BUNDLE_ID`. |
| `Untrusted Developer` / won't open | Trust the cert on the device (above). |
| Stops opening after ~a week | Free cert expired — re-run `make device`. |
| `full Xcode not selected` | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |

## Saves & PC sync

CrossCode keeps its entire save in one `localStorage` blob (`cc.save`) that's **byte-identical to
the desktop save**, so it moves directly between PC and iPhone. cc-ios persists it on-device and
exposes a Files-app backup folder — **no extra setup, no network**:

- **On-device:** every in-game save is written to the app container and survives relaunch.
- **Manual backup/restore:** `Documents/saves/cc.save` is visible in Finder / the Apple Devices app
  / the Files app. Copy it off to back up; drop a replacement in and relaunch to restore (newest
  wins).

**Wireless / USB sync with your PC is an optional add-on:**
**[cc-tailsync](https://github.com/cc-mods/cc-tailsync)** provides USB sync, a macOS/Windows
save-server, and Tailscale wireless sync, and wires itself into this app with one command
(`tools/integrate-ios.sh`). cc-ios itself ships no network sync — it just exposes a fail-safe seam
that cc-tailsync fills in. PC↔PC is handled automatically by **Steam Cloud**.

## Uninstall

Everything cc-ios stores **on the phone** lives inside the app's sandbox container — the save,
the Files-app `saves/` folder, installed mods, and any sync config. So removing it is just a normal
app delete:

1. **On the iPhone:** long-press the **cc-ios** icon → **Remove App** → **Delete App**. This wipes
   the save, mods, and any `cc-sync.json` with it — no leftover files.

> 💾 **Back up the save first if you want it:** Finder/Apple Devices → cc-ios → Files → `saves/cc.save`.
> (If you set up cc-tailsync, it's already on your PC.)

If you set up wireless sync, the **PC save-server** is part of
[cc-tailsync](https://github.com/cc-mods/cc-tailsync) and is separate — stop it from there (see its
docs). **Tailscale itself** is untouched. cc-ios uses no iCloud, App Groups, or Keychain, so nothing
is left behind elsewhere. Your **desktop `cc.save`** (via Steam Cloud) is unaffected.

## Legal

cc-ios is an unofficial fan-made wrapper, **not affiliated with, authorized, or endorsed by Radical
Fish Games**, and contains no CrossCode code or assets. You must own a legal copy of CrossCode and
are responsible for complying with its license. No game assets are distributed here — your files are
git-ignored and only copied locally at build time. This wrapper's **own source code** is MIT
licensed (see [`LICENSE`](LICENSE)); CrossCode, CCLoader, CCModManager, and CrossAndroid belong to
their respective owners.

## Contributing

Start with **[`AGENTS.md`](AGENTS.md)** — it documents the architecture, the non-obvious runtime
invariants that keep CrossCode booting (browser-mode detection, the iOS audio fix, CCLoader/mods,
controller mapping), and the harness-first dev loop. See **[`CONTRIBUTING.md`](CONTRIBUTING.md)** for
ground rules and PR conventions.

## Credits

- **[CrossAndroid](https://gitlab.com/Namnodorel/crossandroid)** by **Namnodorel** — the reference
  implementation that proved the WebView-wrapper approach.
- **[CrossCode](https://www.cross-code.com/)** by **Radical Fish Games**.
- **[CCLoader](https://github.com/CCDirectLink/CCLoader)** + **[CCModManager](https://github.com/CCDirectLink/CCModManager)**
  by the CCDirectLink community.
