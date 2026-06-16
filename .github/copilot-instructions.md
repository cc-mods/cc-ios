# Copilot instructions — cc-ios

**Read [`AGENTS.md`](../AGENTS.md) first.** It is the source of truth for architecture, the runtime
invariants that keep CrossCode booting, the harness-first workflow, and environment gotchas. This
file is just the short version of the must-not-break rules.

📓 **Also read the suite knowledge base:**
**[`cc-mods/knowledge`](https://github.com/cc-mods/knowledge)** (private; org members only) — cross-
suite findings. Most relevant:
[`cc-ios.md`](https://github.com/cc-mods/knowledge/blob/main/cc-ios.md) (the runtime invariants +
the `SaveSyncProvider` seam to cc-tailsync),
[`crosscode-modding.md`](https://github.com/cc-mods/knowledge/blob/main/crosscode-modding.md), and
[`suite-architecture.md`](https://github.com/cc-mods/knowledge/blob/main/suite-architecture.md).
**When you learn something durable, add it to `cc-mods/knowledge`** (and keep `AGENTS.md` in sync).

## Always

- **Never commit game assets** (copyrighted). `app/Resources/game/` and `*.ccmod` are git-ignored —
  keep it so. Check `git status` before committing; no `.ogg/.m4a/.png/game.compiled.js/node-webkit.html`.
- **Never commit personal/machine data**: no real names/emails, `/Users/<name>` paths, Apple Team
  or cert IDs, device UDIDs, LAN/Tailscale IPs, tokens. Use `$HOME`, `userDomainMask`, env vars.
  Commit with a GitHub `noreply` identity, never a corporate email.
- **Prove changes in the macOS harness** before claiming success: `swift run webkit-harness …`
  must boot with `jsErrors == 0` and no `CRITICAL BUG`. The iOS app and harness share
  `Shared/CCWebHost` — keep that code platform-neutral.

## Never (these silently break the game)

- Don't define `window.require` globally or set a custom `userAgent` (flips the game out of
  BROWSER mode).
- Don't remove either half of the audio fix (Ogg→M4A transcode **and** the serve-time M4A format
  patch) — iOS can't decode Ogg.
- Don't make the `ccgame://` scheme handler return non-200 for directory requests (CCLoader's
  existence checks rely on it).
- Don't inject mod game-classes outside the CCLoader `prestart` stage.

## Conventions

Conventional Commits. No `any` in TS/JS. Comment only the non-obvious. Don't add planning/scratch
markdown files to the repo. Keep `README.md` (users) and `AGENTS.md` (agents) in sync with behavior.
