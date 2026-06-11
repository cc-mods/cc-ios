import Foundation
import WebKit

/// JavaScript injected at `documentStart`, before any of CrossCode's own scripts run.
///
/// Its job is to make the NW.js desktop game boot unmodified as a plain browser web
/// app inside WebKit. Two things matter, both verified against the real
/// `game.compiled.js` / `game-base.js`:
///
///  1. **Neutralize NW.js globals.** `node-webkit.html` calls `window.process.once(...)`
///     at parse time; if `process` is undefined the page throws before the game loads.
///     We define a harmless `window.process` shim BUT deliberately leave `window.require`
///     undefined. CrossCode's platform check is:
///       `ig.platform = (window.require && typeof window.process=="object") ? DESKTOP : …`
///     With `require` undefined it skips DESKTOP and (because `navigator.vendor`
///     contains "Apple") resolves to BROWSER — which uses `localStorage` saves and
///     XHR asset loads, never Node `fs`.
///
///  2. **Pipe console + errors to native** so the host can observe boot progress and
///     surface failures (otherwise WebKit swallows them).
public enum Bootstrap {

    /// Name of the `WKScriptMessageHandler` the page posts diagnostics to.
    public static let messageHandlerName = "cchost"

    /// Name of the `WKScriptMessageHandler` the page posts save-data changes to.
    /// Whenever the game writes its save (`localStorage["cc.save"]`), the injected hook
    /// forwards the new value here so the native side can mirror it to a file for syncing.
    public static let saveMessageHandlerName = "ccsave"

    /// Name of the `WKScriptMessageHandler` the title-screen control buttons post to
    /// (`restart` / `quit`). Handled natively by `ControlBridge`.
    public static let controlMessageHandlerName = "cccontrol"

    /// The single localStorage key that holds CrossCode's entire save (browser mode).
    public static let saveKey = "cc.save"

    /// Name of the `WKScriptMessageHandlerWithReply` that backs the `fs` shim's async
    /// filesystem operations (used by CCModManager to install mods to `Documents/mods`).
    public static let fsMessageHandlerName = "ccfs"

    /// JS injected at documentStart that defines a `window.require` returning a minimal
    /// Node-compatible `fs` (with a `.promises` API), a `path` shim, and harmless stubs for
    /// other modules. Backed by a native async bridge (`ccfs`). Safe to expose globally only
    /// because the served `game.compiled.js` is patched to force BROWSER platform
    /// (`GameSchemeHandler.forceBrowserPlatform`); otherwise defining `require` would make
    /// CrossCode behave as the NW.js desktop build.
    ///
    /// This is what makes CCModManager's one-click install work on iOS: its
    /// `fs.promises.writeFile("assets/mods/<id>.ccmod", bytes)` is routed to the native
    /// bridge, which writes into the writable `Documents/mods` overlay.
    public static let fsShimJavaScript: String = #"""
    (function () {
      "use strict";

      function call(op, args) {
        try {
          return window.webkit.messageHandlers.ccfs.postMessage(
            Object.assign({ op: op }, args)
          );
        } catch (e) {
          return Promise.reject(new Error("ccfs bridge unavailable"));
        }
      }

      // Native replies send file bytes back as a base64 string; decode to a Uint8Array.
      function b64ToBytes(b64) {
        var bin = atob(b64), len = bin.length, out = new Uint8Array(len);
        for (var i = 0; i < len; i++) out[i] = bin.charCodeAt(i);
        return out;
      }
      function toBase64(data) {
        var bytes = (data instanceof Uint8Array) ? data
          : (data instanceof ArrayBuffer) ? new Uint8Array(data)
          : (typeof data === "string") ? new TextEncoder().encode(data)
          : new Uint8Array(data || []);
        var bin = "";
        for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
        return btoa(bin);
      }

      var promises = {
        writeFile: function (p, data) {
          return call("writeFile", { path: String(p), dataB64: toBase64(data) }).then(function () {});
        },
        readFile: function (p, opts) {
          return call("readFile", { path: String(p) }).then(function (b64) {
            var bytes = b64ToBytes(b64 || "");
            var enc = (typeof opts === "string") ? opts : (opts && opts.encoding);
            return enc ? new TextDecoder().decode(bytes) : bytes;
          });
        },
        mkdir: function (p) { return call("mkdir", { path: String(p) }).then(function () {}); },
        readdir: function (p) { return call("readdir", { path: String(p) }); },
        stat: function (p) {
          return call("stat", { path: String(p) }).then(function (s) {
            if (!s || !s.exists) { var e = new Error("ENOENT"); e.code = "ENOENT"; throw e; }
            return { size: s.size, isDirectory: function () { return !!s.dir; },
                     isFile: function () { return !s.dir; }, mtimeMs: s.mtimeMs || 0 };
          });
        },
        access: function (p) {
          return call("stat", { path: String(p) }).then(function (s) {
            if (!s || !s.exists) { var e = new Error("ENOENT"); e.code = "ENOENT"; throw e; }
          });
        },
        unlink: function (p) { return call("unlink", { path: String(p) }).then(function () {}); }
      };

      // Node callback-style API (last arg is callback(err, result)). CCLoader's logger and
      // some libs call these directly off `require("fs")`. File-logging targets (log.txt,
      // biglog.txt — outside the mods dir) are no-op'd so they don't spam the bridge.
      function lastFn(args) {
        var cb = args[args.length - 1];
        return (typeof cb === "function") ? cb : function () {};
      }
      function isLogPath(p) { return /(^|\/)(big)?log\.txt$/.test(String(p)); }

      var cb = {
        appendFile: function () { lastFn(arguments)(null); },
        truncate: function () { lastFn(arguments)(null); },
        writeFile: function (p, data) {
          var done = lastFn(arguments);
          if (isLogPath(p)) { return done(null); }
          promises.writeFile(p, data).then(function () { done(null); }, done);
        },
        readFile: function (p) {
          var done = lastFn(arguments);
          var opts = (typeof arguments[1] !== "function") ? arguments[1] : undefined;
          promises.readFile(p, opts).then(function (d) { done(null, d); }, done);
        },
        mkdir: function (p) {
          var done = lastFn(arguments);
          promises.mkdir(p).then(function () { done(null); }, done);
        },
        readdir: function (p) {
          var done = lastFn(arguments);
          promises.readdir(p).then(function (l) { done(null, l); }, done);
        },
        stat: function (p) {
          var done = lastFn(arguments);
          if (isLogPath(p)) { var e = new Error("ENOENT"); e.code = "ENOENT"; return done(e); }
          promises.stat(p).then(function (s) { done(null, s); }, done);
        },
        unlink: function (p) {
          var done = lastFn(arguments);
          promises.unlink(p).then(function () { done(null); }, done);
        },
        realpath: function (p) { lastFn(arguments)(null, String(p)); },
        exists: function (p) {
          var done = lastFn(arguments);
          promises.stat(p).then(function () { done(true); }, function () { done(false); });
        }
      };
      cb.lstat = cb.stat;

      var fsShim = {
        promises: promises,
        appendFile: cb.appendFile, truncate: cb.truncate, writeFile: cb.writeFile,
        readFile: cb.readFile, mkdir: cb.mkdir, readdir: cb.readdir, stat: cb.stat,
        lstat: cb.lstat, unlink: cb.unlink, realpath: cb.realpath, exists: cb.exists,
        constants: { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1 },
        existsSync: function () { return false; }
      };

      var pathShim = {
        sep: "/",
        join: function () { return Array.prototype.join.call(arguments, "/").replace(/\/+/g, "/"); },
        dirname: function (p) { return String(p).replace(/\/[^/]*$/, "") || "/"; },
        basename: function (p) { return String(p).replace(/^.*\//, ""); },
        extname: function (p) { var m = /\.[^./]+$/.exec(String(p)); return m ? m[0] : ""; },
        resolve: function () { return Array.prototype.join.call(arguments, "/").replace(/\/+/g, "/"); }
      };

      // nw.gui stub: CrossCode only touches this on external-link clicks; route to window.open.
      var nwGuiShim = {
        Shell: { openExternal: function (u) { try { window.open(u, "_blank"); } catch (e) {} } },
        Window: { get: function () { return { isFullscreen: false, enterFullscreen: function () {},
                  leaveFullscreen: function () {}, close: function () {}, on: function () {},
                  showDevTools: function () {}, isDevToolsOpen: function () { return false; } }; },
                  open: function () {} },
        App: { dataPath: "/", argv: [], clearCache: function () {} }
      };

      window.require = function (m) {
        if (m === "fs") return fsShim;
        if (m === "path") return pathShim;
        if (m === "nw.gui") return nwGuiShim;
        return {};
      };
    })();
    """#

    /// documentStart `WKUserScript` installing the `require`/`fs` shim (mod-install support).
    public static func fsShimUserScript() -> WKUserScript {
        WKUserScript(source: fsShimJavaScript,
                     injectionTime: .atDocumentStart,
                     forMainFrameOnly: true)
    }

    public static let javaScript: String = #"""
    (function () {
      "use strict";

      function post(payload) {
        try {
          window.webkit.messageHandlers.cchost.postMessage(payload);
        } catch (e) { /* handler not registered (e.g. plain browser) — ignore */ }
      }

      // --- 1. Console + error piping ------------------------------------------------
      ["log", "info", "warn", "error", "debug"].forEach(function (level) {
        var original = (typeof console[level] === "function")
          ? console[level].bind(console)
          : function () {};
        console[level] = function () {
          try {
            var parts = Array.prototype.map.call(arguments, function (a) {
              if (typeof a === "string") return a;
              try { return JSON.stringify(a); } catch (e) { return String(a); }
            });
            post({ type: "console", level: level, message: parts.join(" ") });
          } catch (e) { /* never let logging break the game */ }
          original.apply(console, arguments);
        };
      });

      window.addEventListener("error", function (e) {
        post({
          type: "error",
          message: (e && e.message ? e.message : "error") +
                   " @ " + (e && e.filename ? e.filename : "?") +
                   ":" + (e && e.lineno ? e.lineno : 0)
        });
      });
      window.addEventListener("unhandledrejection", function (e) {
        var reason = e && e.reason;
        post({
          type: "error",
          message: "unhandledrejection: " +
                   (reason && reason.message ? reason.message : String(reason))
        });
      });

      // --- 2. NW.js neutralization --------------------------------------------------
      // Provide a no-op `process` so `node-webkit.html`'s parse-time
      // `window['process'].once(...)` succeeds. Crucially DO NOT define `window.require`
      // (keeps platform detection on the BROWSER path) and keep `versions` empty so
      // `game-base.js`'s `process.versions['node-webkit']` guard stays falsy.
      if (typeof window.process === "undefined") {
        var noop = function () { return window.process; };
        window.process = {
          once: noop,
          on: noop,
          off: noop,
          emit: noop,
          env: {},
          versions: {},
          platform: "ios",
          argv: [],
          nextTick: function (cb) { if (typeof cb === "function") setTimeout(cb, 0); }
        };
      }

      post({ type: "status", message: "bootstrap-installed" });

      // --- 3. Save capture ----------------------------------------------------------
      // Mirror every write of the game's save key to the native side so it can be
      // persisted to a file and synced with the desktop/Steam copy. The save lives in a
      // single localStorage key; wrapping setItem captures it the instant the game saves.
      // NOTE: patch Storage.prototype (not the localStorage instance) — WebKit's localStorage
      // is a host object whose instance methods can't be reliably overridden.
      try {
        var proto = window.Storage && window.Storage.prototype;
        if (proto && typeof proto.setItem === "function" && !proto.__ccSaveHooked) {
          var rawSetItem = proto.setItem;
          proto.setItem = function (key, value) {
            rawSetItem.call(this, key, value);
            if (key === "cc.save") {
              try {
                window.webkit.messageHandlers.ccsave.postMessage(String(value));
              } catch (e) { /* handler not registered (macOS harness) — ignore */ }
            }
          };
          proto.__ccSaveHooked = true;
        }
      } catch (e) { /* never let the hook break the game */ }
    })();
    """#

    /// Builds the `WKUserScript` that runs the bootstrap at document start.
    public static func userScript() -> WKUserScript {
        WKUserScript(source: javaScript,
                     injectionTime: .atDocumentStart,
                     forMainFrameOnly: true)
    }

    /// Builds a documentStart `WKUserScript` that pre-populates `localStorage["cc.save"]`
    /// with a previously-synced save, so the game boots with it already in place.
    ///
    /// The save (164 KB of AES/base64 JSON) is passed base64-encoded to sidestep all
    /// JS string-escaping concerns; the page decodes it with `atob`. Must be added to the
    /// content controller **before** the main bootstrap script so the value is present
    /// when CrossCode first reads it.
    public static func saveInjectionUserScript(base64Save: String) -> WKUserScript {
        let source = """
        (function () {
          try {
            var data = atob("\(base64Save)");
            window.localStorage.setItem("cc.save", data);
          } catch (e) { /* malformed payload — leave any existing save untouched */ }
        })();
        """
        return WKUserScript(source: source,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: true)
    }

    /// JS that backs `navigator.getGamepads()` with a virtual gamepad fed by the native
    /// GameController bridge (`ControllerBridge`).
    ///
    /// CrossCode reads input through the standard Web Gamepad API: `ig.Html5GamepadHandler`
    /// polls `navigator.getGamepads()` each frame and reads `buttons[0..15]` / `axes[0..3]`
    /// in the **W3C standard mapping** (verified against the binary). On iOS, WebKit does not
    /// reliably expose Bluetooth controllers to a custom‑scheme page, so instead the native
    /// side pushes controller state into `window.__ccpad.update(buttons, axes)` and we
    /// override `getGamepads()` to return that virtual pad. When no native pad is connected
    /// we fall through to the real implementation, so behaviour is unchanged elsewhere.
    public static let gamepadShimJavaScript: String = #"""
    (function () {
      "use strict";
      var pad = null;
      var realGet = (navigator.getGamepads || navigator.webkitGetGamepads ||
                     function () { return []; }).bind(navigator);

      function now() {
        return (window.performance && performance.now) ? performance.now() : Date.now();
      }
      function makePad() {
        var b = [];
        for (var i = 0; i < 17; i++) b.push({ pressed: false, touched: false, value: 0 });
        return { id: "CrossCode Controller (Standard)", index: 0, connected: true,
                 mapping: "standard", buttons: b, axes: [0, 0, 0, 0], timestamp: now() };
      }

      window.__ccpad = {
        connect: function () {
          if (!pad) pad = makePad();
          pad.connected = true;
          try {
            var ev = (typeof GamepadEvent === "function")
              ? new GamepadEvent("gamepadconnected", { gamepad: pad })
              : new Event("gamepadconnected");
            if (!ev.gamepad) { try { ev.gamepad = pad; } catch (e) {} }
            window.dispatchEvent(ev);
          } catch (e) {}
        },
        disconnect: function () {
          if (pad) {
            pad.connected = false;
            try {
              var ev = (typeof GamepadEvent === "function")
                ? new GamepadEvent("gamepaddisconnected", { gamepad: pad })
                : new Event("gamepaddisconnected");
              if (!ev.gamepad) { try { ev.gamepad = pad; } catch (e) {} }
              window.dispatchEvent(ev);
            } catch (e) {}
          }
          pad = null;
        },
        update: function (buttons, axes) {
          if (!pad) this.connect();
          for (var i = 0; i < buttons.length && i < pad.buttons.length; i++) {
            var v = buttons[i];
            pad.buttons[i].value = v;
            pad.buttons[i].pressed = v > 0.1;
            pad.buttons[i].touched = v > 0.1;
          }
          for (var j = 0; j < axes.length && j < pad.axes.length; j++) pad.axes[j] = axes[j];
          pad.timestamp = now();
        }
      };

      navigator.getGamepads = function () { return pad ? [pad] : realGet(); };
      navigator.webkitGetGamepads = navigator.getGamepads;
    })();
    """#

    /// documentStart `WKUserScript` installing the gamepad shim (see ``gamepadShimJavaScript``).
    public static func gamepadShimUserScript() -> WKUserScript {
        WKUserScript(source: gamepadShimJavaScript,
                     injectionTime: .atDocumentStart,
                     forMainFrameOnly: true)
    }

    /// JS that draws a small live FPS counter in the **top-right** corner, over the game.
    ///
    /// Measures real frames via `requestAnimationFrame` (independent of the engine's target
    /// `ig.system.fps`), updating ~2×/sec. Self-healing against CCLoader's `document.write`
    /// by re-attaching its element from a persistent `window` timer. Colour-coded:
    /// green ≥55, amber ≥30, red below.
    public static let fpsOverlayJavaScript: String = #"""
    (function () {
      "use strict";
      if (window.__ccFpsInstalled) return;
      window.__ccFpsInstalled = true;

      var el = null, frames = 0, last = (performance && performance.now) ? performance.now() : Date.now(), fps = 0;

      function hasGameCanvas() {
        try { return !!document.querySelector("#canvas, canvas"); } catch (e) { return false; }
      }

      function ensureEl() {
        // Only render in the frame that actually hosts the game canvas. Under CCLoader
        // that's the child iframe; for a direct boot it's the main frame.
        if (!hasGameCanvas()) return null;
        var root = document.body || document.documentElement;
        if (!root) return null;
        if (el && el.parentNode) return el;
        el = document.getElementById("ccios-fps");
        if (!el) {
          el = document.createElement("div");
          el.id = "ccios-fps";
          el.style.cssText = [
            "position:fixed", "top:6px", "right:8px", "z-index:2147483647",
            "font:700 12px ui-monospace,Menlo,monospace", "padding:2px 6px",
            "color:#7CFC8A", "background:rgba(0,0,0,0.55)", "border-radius:6px",
            "pointer-events:none", "-webkit-user-select:none", "user-select:none"
          ].join(";");
          root.appendChild(el);
        }
        return el;
      }

      function frame(now) {
        frames++;
        var dt = now - last;
        if (dt >= 500) {
          fps = Math.round((frames * 1000) / dt);
          frames = 0; last = now;
          var e = ensureEl();
          if (e) {
            e.textContent = fps + " FPS";
            e.style.color = fps >= 55 ? "#7CFC8A" : (fps >= 30 ? "#FFD24A" : "#FF6B6B");
          }
        }
        requestAnimationFrame(frame);
      }
      requestAnimationFrame(frame);
    })();
    """#

    /// documentEnd `WKUserScript` installing the FPS overlay (see ``fpsOverlayJavaScript``).
    public static func fpsOverlayUserScript() -> WKUserScript {
        WKUserScript(source: fpsOverlayJavaScript,
                     injectionTime: .atDocumentEnd,
                     forMainFrameOnly: false)
    }
}
