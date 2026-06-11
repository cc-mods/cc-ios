# Contributing to cc-ios

Thanks for your interest! cc-ios is a **WKWebView wrapper** that runs your own copy of CrossCode on
iOS. A few things make this project unusual — please skim this before opening a PR.

> **AI agents:** see [`AGENTS.md`](AGENTS.md) for the full working guide (architecture, runtime
> invariants, harness workflow). It applies to humans too.

## Ground rules

- **No game assets, ever.** CrossCode is copyrighted; everyone supplies their own legally-owned
  copy. `app/Resources/game/` and `*.ccmod` are git-ignored. Double-check `git status` before
  committing — nothing like `node-webkit.html`, `game.compiled.js`, `.ogg`, `.m4a`, or game art
  should be staged.
- **No personal data.** No real emails, `/Users/<name>` paths, Apple Team/cert IDs, device UDIDs,
  or private IPs in code or commits. Use `$HOME`, `userDomainMask`, env vars, and CLI flags. Commit
  with a GitHub `noreply` email.
- This wrapper's own code is MIT (see `LICENSE`). Don't add code you can't license that way.

## Getting set up

```bash
make doctor    # verify your toolchain (use ARGS="--fix" to auto-install brew tools)
make setup     # find your CrossCode copy, sync+transcode assets, generate the Xcode project
make harness   # boot the game in a macOS WKWebView — the fastest dev loop
```

You need a Mac with full Xcode, `xcodegen` + `ffmpeg` (Homebrew), and your own CrossCode install.
See `README.md` → Installation for details, including the Apple signing steps for device builds.

## Development loop

Most behavior lives in `Shared/CCWebHost/` — shared by the iOS app **and** the macOS harness.
Develop against the harness (no device, no signing), then validate on Simulator/device.

```bash
swift build
./.build/debug/webkit-harness --root app/Resources/game --entry ccloader/index.html \
  --prefer-m4a --mods-overlay /tmp/cc-overlay --fps --settle 12
```

A change is "done" when the harness boots with `jsErrors == 0` and no `CRITICAL BUG`, the specific
behavior is demonstrated (screenshot/`--eval`/`--ls-get`), and no assets or personal data are
staged. There is no separate unit-test suite — the harness boot is the test.

## Pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`,
  `chore:`, `build:`; scopes like `feat(host):`).
- Keep `Shared/CCWebHost` platform-neutral; don't fork host logic per platform.
- Update `README.md` (user-facing) and `AGENTS.md` (agent-facing) when you change behavior or the
  install flow.
- Describe how you verified the change (harness output, Simulator, or device).
