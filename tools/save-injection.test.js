/* Headless test for the save-injection user script (no WKWebView, no app launch).
 *
 * Extracts the ACTUAL JS embedded in Bootstrap.swift's `saveInjectionUserScript(...)` and runs it
 * against fake `window.sessionStorage` / `window.localStorage` to prove the data-loss fix:
 *
 *   - It SEEDS localStorage on the first load of a browsing context (app launch).
 *   - It SKIPS re-seeding on a reload (the "Restart Game" button / cc-ultrawide restart prompt call
 *     webView.reload(), which re-runs documentStart user scripts) — so the live, freshly-played save
 *     is NOT clobbered by the stale launch-time snapshot. This is the reported bug.
 *   - A genuine app relaunch (fresh WKWebView → fresh sessionStorage) seeds again from the (current)
 *     Documents/cc.save snapshot.
 *   - Fail-safe: if sessionStorage is unavailable it does NOT seed (never clobbers an existing save).
 *
 * Run: `node tools/save-injection.test.js`.
 */
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

let pass = 0, fail = 0;
function ok(name, cond) { if (cond) { pass++; } else { fail++; console.error("  FAIL: " + name); } }

// ---- Extract the JS template from Bootstrap.swift ------------------------------------
const swift = fs.readFileSync(
  path.join(__dirname, "..", "Shared", "CCWebHost", "Bootstrap.swift"), "utf8");

// Grab the body of `saveInjectionUserScript`, then the `let source = """ … """` block within it.
const fnIdx = swift.indexOf("func saveInjectionUserScript");
if (fnIdx < 0) { console.error("could not find saveInjectionUserScript in Bootstrap.swift"); process.exit(1); }
const after = swift.slice(fnIdx);
const m = after.match(/let source = """\n([\s\S]*?)\n\s*"""/);
if (!m) { console.error("could not extract the source JS string"); process.exit(1); }
const jsTemplate = m[1];

// Build a runnable script for a given base64 payload (Swift interpolates \(base64Save)).
function scriptFor(base64) {
  return jsTemplate.replace("\\(base64Save)", base64);
}
function b64(s) { return Buffer.from(s, "binary").toString("base64"); }

// ---- Fake storages -------------------------------------------------------------------
function makeStorage(initial) {
  const store = Object.assign({}, initial);
  return {
    getItem: (k) => (Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null),
    setItem: (k, v) => { store[k] = String(v); },
    removeItem: (k) => { delete store[k]; },
    _store: store,
  };
}
// A browsing context = one sessionStorage that survives reloads; localStorage persists across
// relaunches (WebKit per-origin durability). We model a relaunch as a NEW sessionStorage but the
// SAME localStorage object carried over.
function runLoad(win, base64) {
  vm.runInNewContext(scriptFor(base64), { window: win, atob });
}

// ---- Scenario: launch → play → restart(reload) → relaunch ---------------------------
(function () {
  // localStorage may already hold last session's save (WebKit-persisted). sessionStorage is fresh.
  const localStorage = makeStorage({ "cc.save": "STALE_FROM_LAST_SESSION" });
  let sessionStorage = makeStorage({});
  const win = { localStorage, sessionStorage };

  // 1) App launch — Documents/cc.save snapshot is "MORNING". First load seeds it.
  runLoad(win, b64("MORNING"));
  ok("launch seeds the snapshot into localStorage", localStorage.getItem("cc.save") === "MORNING");
  ok("launch sets the sessionStorage guard", sessionStorage.getItem("__ccSaveSeeded") === "1");

  // 2) Player plays 30 min; the game writes a fresh save to localStorage (autosave + manual).
  localStorage.setItem("cc.save", "FRESH_30MIN");

  // 3) "Restart Game" → webView.reload(): SAME browsing context (sessionStorage persists), the
  //    documentStart script re-runs with the SAME baked "MORNING" snapshot. MUST NOT clobber.
  runLoad(win, b64("MORNING"));
  ok("reload does NOT re-inject (live save preserved)", localStorage.getItem("cc.save") === "FRESH_30MIN");

  // 4) Genuine app relaunch: new WKWebView → fresh sessionStorage; Documents/cc.save is current
  //    ("FRESH_30MIN", kept by the save hook), so the new snapshot seeds correctly.
  sessionStorage = makeStorage({});
  win.sessionStorage = sessionStorage;
  runLoad(win, b64("FRESH_30MIN"));
  ok("relaunch re-seeds from the CURRENT snapshot", localStorage.getItem("cc.save") === "FRESH_30MIN");
})();

// ---- Sync-restore still works: a launch applies an externally-newer save ------------
(function () {
  const localStorage = makeStorage({ "cc.save": "OLD_PHONE_SAVE" });
  const win = { localStorage, sessionStorage: makeStorage({}) };
  // pullIfNewerBlocking pulled a newer desktop save → snapshot is "NEW_DESKTOP". Launch seeds it.
  runLoad(win, b64("NEW_DESKTOP"));
  ok("launch applies an externally-synced newer save", localStorage.getItem("cc.save") === "NEW_DESKTOP");
})();

// ---- Fail-safe: no sessionStorage → do NOT seed (never clobber a live save) ----------
(function () {
  const localStorage = makeStorage({ "cc.save": "LIVE" });
  const throwing = { getItem: () => { throw new Error("no sessionStorage"); }, setItem: () => {} };
  const win = { localStorage, sessionStorage: throwing };
  runLoad(win, b64("SNAPSHOT"));
  ok("no sessionStorage → leaves the live save untouched", localStorage.getItem("cc.save") === "LIVE");
})();

console.log((fail === 0 ? "ok" : "FAILED") + " — save-injection: " + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
