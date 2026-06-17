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
        readdir: function (p, opts) {
          var withTypes = opts && (opts === true || opts.withFileTypes);
          return call("readdir", { path: String(p) }).then(function (list) {
            list = list || [];
            // Native now returns [{name, dir}]; tolerate a legacy [String] reply too.
            return list.map(function (e) {
              var name = (e && typeof e === "object") ? e.name : e;
              if (!withTypes) return name;
              var isDir = !!(e && typeof e === "object" && e.dir);
              return { name: name, isDirectory: function () { return isDir; },
                       isFile: function () { return !isDir; }, isSymbolicLink: function () { return false; } };
            });
          });
        },
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
          var opts = (typeof arguments[1] !== "function") ? arguments[1] : undefined;
          promises.readdir(p, opts).then(function (l) { done(null, l); }, done);
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

      // --- Synchronous reads via the ccgame:// scheme -------------------------------
      // The native fs bridge is async-only, so readFileSync etc. can't go through it. But
      // the scheme handler also *serves* the bundle + Documents/mods overlay over
      // ccgame://, and XMLHttpRequest supports synchronous mode — and the handler responds
      // synchronously, exactly as the game's own asset loads do. So back the sync reads with
      // a blocking XHR against ccgame://game/<path>. (Sync *writes* still aren't possible.)
      function ccURL(p) {
        p = String(p);
        if (/^[a-z][a-z0-9+.-]*:\/\//i.test(p)) return p;   // already absolute URL
        p = p.replace(/^\.?\//, "");                         // strip leading "./" or "/"
        return "ccgame://game/" + p;
      }
      function syncGet(p) {
        var xhr = new XMLHttpRequest();
        xhr.open("GET", ccURL(p), false);                    // false = synchronous
        try { xhr.overrideMimeType("text/plain; charset=x-user-defined"); } catch (e) {}
        xhr.send(null);
        return xhr;
      }
      function enoent(p) { var e = new Error("ENOENT: no such file or directory, '" + p + "'"); e.code = "ENOENT"; return e; }
      function binStringToBytes(s) {
        var out = new Uint8Array(s.length);
        for (var i = 0; i < s.length; i++) out[i] = s.charCodeAt(i) & 0xff;
        return out;
      }

      var fsShim = {
        promises: promises,
        appendFile: cb.appendFile, truncate: cb.truncate, writeFile: cb.writeFile,
        readFile: cb.readFile, mkdir: cb.mkdir, readdir: cb.readdir, stat: cb.stat,
        lstat: cb.lstat, unlink: cb.unlink, realpath: cb.realpath, exists: cb.exists,
        constants: { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1 },

        // Synchronous reads (backed by sync XHR against ccgame://).
        existsSync: function (p) {
          try { var x = syncGet(p); return x.status !== 404 && x.status !== 0; } catch (e) { return false; }
        },
        readFileSync: function (p, opts) {
          var x = syncGet(p);
          if (x.status === 404 || x.status === 0) throw enoent(p);
          var enc = (typeof opts === "string") ? opts : (opts && opts.encoding);
          var bytes = binStringToBytes(x.responseText || "");
          return enc ? new TextDecoder().decode(bytes) : bytes;
        },
        statSync: function (p) {
          var x = syncGet(p);
          if (x.status === 404 || x.status === 0) throw enoent(p);
          var isDir = x.getResponseHeader("X-CC-Dir") === "1";
          var size = (x.responseText || "").length;
          return { size: size, isDirectory: function () { return isDir; },
                   isFile: function () { return !isDir; }, isSymbolicLink: function () { return false; },
                   mtimeMs: 0 };
        },
        realpathSync: function (p) { return String(p); },
        // Sync directory listing can't be served over a single XHR; callers should use the
        // async readdir (the install path does). Fail clearly rather than lie with [].
        readdirSync: function (p) {
          var e = new Error("ENOSYS: readdirSync is not supported on iOS; use async readdir"); e.code = "ENOSYS"; throw e;
        },
        // Sync writes have no path through the async bridge — fail clearly.
        writeFileSync: function () { var e = new Error("ENOSYS: writeFileSync is not supported on iOS; use async writeFile"); e.code = "ENOSYS"; throw e; },
        mkdirSync: function () { var e = new Error("ENOSYS: mkdirSync is not supported on iOS; use async mkdir"); e.code = "ENOSYS"; throw e; }
      };
      fsShim.lstatSync = fsShim.statSync;

      var pathShim = {
        sep: "/",
        delimiter: ":",
        join: function () {
          var parts = Array.prototype.filter.call(arguments, function (a) { return a != null && a !== ""; });
          return parts.join("/").replace(/\/+/g, "/");
        },
        dirname: function (p) { return String(p).replace(/\/+$/, "").replace(/\/[^/]*$/, "") || (/^\//.test(p) ? "/" : "."); },
        basename: function (p, ext) {
          var b = String(p).replace(/\/+$/, "").replace(/^.*\//, "");
          if (ext && b.slice(-ext.length) === ext) b = b.slice(0, -ext.length);
          return b;
        },
        extname: function (p) { var m = /(?!^)\.[^./]+$/.exec(String(p).replace(/^.*\//, "")); return m ? m[0] : ""; },
        isAbsolute: function (p) { return /^\//.test(String(p)); },
        normalize: function (p) {
          p = String(p);
          var abs = /^\//.test(p), trail = /\/$/.test(p);
          var out = [];
          p.split("/").forEach(function (seg) {
            if (seg === "" || seg === ".") return;
            if (seg === "..") { if (out.length && out[out.length - 1] !== "..") out.pop(); else if (!abs) out.push(".."); }
            else out.push(seg);
          });
          var s = out.join("/");
          if (abs) s = "/" + s;
          if (trail && s && !/\/$/.test(s)) s += "/";
          return s || (abs ? "/" : ".");
        },
        resolve: function () {
          var resolved = "";
          for (var i = arguments.length - 1; i >= 0 && resolved.charAt(0) !== "/"; i--) {
            var seg = arguments[i];
            if (seg == null || seg === "") continue;
            resolved = seg + "/" + resolved;
          }
          var abs = /^\//.test(resolved);
          resolved = pathShim.normalize(resolved);
          if (abs && resolved.charAt(0) !== "/") resolved = "/" + resolved;
          return resolved.replace(/\/$/, "") || (abs ? "/" : ".");
        },
        relative: function (from, to) {
          from = pathShim.resolve(from).split("/"); to = pathShim.resolve(to).split("/");
          var i = 0; while (i < from.length && i < to.length && from[i] === to[i]) i++;
          var up = []; for (var j = i; j < from.length; j++) if (from[j]) up.push("..");
          return up.concat(to.slice(i)).join("/");
        },
        parse: function (p) {
          var dir = pathShim.dirname(p), base = pathShim.basename(p), ext = pathShim.extname(p);
          return { root: /^\//.test(String(p)) ? "/" : "", dir: dir, base: base, ext: ext, name: ext ? base.slice(0, -ext.length) : base };
        },
        format: function (o) {
          o = o || {};
          var base = o.base || ((o.name || "") + (o.ext || ""));
          var dir = o.dir || o.root || "";
          return dir ? (dir.replace(/\/$/, "") + "/" + base) : base;
        }
      };
      pathShim.posix = pathShim;

      // nw.gui stub: CrossCode only touches this on external-link clicks; route to the
      // native external-link hook (see externalLinkJavaScript), falling back to window.open.
      var nwGuiShim = {
        Shell: { openExternal: function (u) {
          try { if (window.__ccOpenExternal && window.__ccOpenExternal(u)) return; } catch (e) {}
          try { window.open(u, "_blank"); } catch (e) {}
        } },
        Window: { get: function () { return { isFullscreen: false, enterFullscreen: function () {},
                  leaveFullscreen: function () {}, close: function () {}, on: function () {},
                  showDevTools: function () {}, isDevToolsOpen: function () { return false; } }; },
                  open: function () {} },
        App: { dataPath: "/", argv: [], clearCache: function () {} }
      };

      // --- events.EventEmitter (pure JS, also used by the http shim below) -------------
      function EventEmitter() { this._ev = {}; }
      EventEmitter.prototype.on = function (n, fn) { (this._ev[n] = this._ev[n] || []).push(fn); return this; };
      EventEmitter.prototype.addListener = EventEmitter.prototype.on;
      EventEmitter.prototype.once = function (n, fn) {
        var self = this; function w() { self.removeListener(n, w); fn.apply(this, arguments); }
        w.__orig = fn; return this.on(n, w);
      };
      EventEmitter.prototype.removeListener = function (n, fn) {
        var a = this._ev[n]; if (!a) return this;
        this._ev[n] = a.filter(function (f) { return f !== fn && f.__orig !== fn; }); return this;
      };
      EventEmitter.prototype.off = EventEmitter.prototype.removeListener;
      EventEmitter.prototype.removeAllListeners = function (n) { if (n) delete this._ev[n]; else this._ev = {}; return this; };
      EventEmitter.prototype.emit = function (n) {
        var a = (this._ev[n] || []).slice(), args = Array.prototype.slice.call(arguments, 1);
        a.forEach(function (f) { try { f.apply(null, args); } catch (e) {} });
        return a.length > 0;
      };
      EventEmitter.prototype.listeners = function (n) { return (this._ev[n] || []).slice(); };
      EventEmitter.prototype.setMaxListeners = function () { return this; };
      var eventsShim = { EventEmitter: EventEmitter };

      // --- util ------------------------------------------------------------------------
      var utilShim = {
        inherits: function (ctor, superCtor) {
          ctor.super_ = superCtor;
          ctor.prototype = Object.create(superCtor.prototype, { constructor: { value: ctor, enumerable: false, writable: true, configurable: true } });
        },
        inspect: function (o) { try { return typeof o === "string" ? o : JSON.stringify(o); } catch (e) { return String(o); } },
        format: function (f) {
          var args = Array.prototype.slice.call(arguments, 1), i = 0;
          if (typeof f !== "string") return [f].concat(args).map(function (a) { return utilShim.inspect(a); }).join(" ");
          var out = f.replace(/%[sdjifoO%]/g, function (m) {
            if (m === "%%") return "%";
            if (i >= args.length) return m;
            var a = args[i++];
            if (m === "%d" || m === "%i") return String(parseInt(a, 10));
            if (m === "%f") return String(parseFloat(a));
            if (m === "%j") { try { return JSON.stringify(a); } catch (e) { return "[Circular]"; } }
            if (m === "%s") return String(a);
            return utilShim.inspect(a);
          });
          for (; i < args.length; i++) out += " " + utilShim.inspect(args[i]);
          return out;
        },
        promisify: function (fn) {
          return function () {
            var args = Array.prototype.slice.call(arguments), self = this;
            return new Promise(function (resolve, reject) {
              args.push(function (err, res) { if (err) reject(err); else resolve(res); });
              fn.apply(self, args);
            });
          };
        },
        deprecate: function (fn) { return fn; },
        isArray: Array.isArray,
        isFunction: function (v) { return typeof v === "function"; },
        isObject: function (v) { return v !== null && typeof v === "object"; },
        isString: function (v) { return typeof v === "string"; },
        isNumber: function (v) { return typeof v === "number"; },
        isUndefined: function (v) { return v === undefined; },
        isNullOrUndefined: function (v) { return v == null; },
        types: { isDate: function (v) { return v instanceof Date; } },
        TextEncoder: (typeof TextEncoder !== "undefined") ? TextEncoder : undefined,
        TextDecoder: (typeof TextDecoder !== "undefined") ? TextDecoder : undefined
      };

      // --- assert ----------------------------------------------------------------------
      function AssertionError(msg) { var e = new Error(msg || "assertion failed"); e.name = "AssertionError"; e.code = "ERR_ASSERTION"; return e; }
      function assertShim(v, msg) { if (!v) throw AssertionError(msg); }
      assertShim.ok = assertShim;
      assertShim.equal = function (a, b, m) { if (a != b) throw AssertionError(m || (a + " == " + b)); };
      assertShim.notEqual = function (a, b, m) { if (a == b) throw AssertionError(m || (a + " != " + b)); };
      assertShim.strictEqual = function (a, b, m) { if (a !== b) throw AssertionError(m || (a + " === " + b)); };
      assertShim.notStrictEqual = function (a, b, m) { if (a === b) throw AssertionError(m || (a + " !== " + b)); };
      assertShim.deepEqual = function (a, b, m) { try { assertShim.strictEqual(JSON.stringify(a), JSON.stringify(b), m); } catch (e) { throw AssertionError(m); } };
      assertShim.deepStrictEqual = assertShim.deepEqual;
      assertShim.fail = function (m) { throw AssertionError(m || "failed"); };
      assertShim.throws = function (fn, m) { var t = false; try { fn(); } catch (e) { t = true; } if (!t) throw AssertionError(m || "missing expected exception"); };
      assertShim.AssertionError = AssertionError;

      // --- http / https → fetch --------------------------------------------------------
      // Node's http(s).get/request, mapped onto fetch with a minimal EventEmitter response
      // (.on("data"|"end"|"error")). Covers the common "fetch a URL and read the body" case;
      // streaming/keep-alive/sockets are not emulated.
      function makeHttp(defaultProto) {
        function request(opts, cb) {
          var url, method = "GET", headers = {};
          if (typeof opts === "string") { url = opts; }
          else if (opts && opts.url) { url = opts.url; method = opts.method || method; headers = opts.headers || {}; }
          else if (opts) {
            var proto = opts.protocol || (defaultProto + ":");
            var host = opts.hostname || opts.host || "";
            var port = opts.port ? (":" + opts.port) : "";
            url = proto + "//" + host + port + (opts.path || "/");
            method = opts.method || method; headers = opts.headers || {};
          }
          var res = new EventEmitter();
          res.statusCode = 0; res.headers = {};
          var req = new EventEmitter();
          req.end = function () {
            fetch(url, { method: method, headers: headers }).then(function (r) {
              res.statusCode = r.status;
              try { r.headers.forEach(function (v, k) { res.headers[k] = v; }); } catch (e) {}
              if (cb) cb(res);
              return r.text().then(function (body) { res.emit("data", body); res.emit("end"); });
            }).catch(function (err) { req.emit("error", err); res.emit("error", err); });
            return req;
          };
          req.write = function () { return true; };
          req.abort = function () {};
          req.setTimeout = function () { return req; };
          req.on("__noop__", function () {});
          // http.get auto-ends the request.
          return req;
        }
        return {
          request: request,
          get: function (opts, cb) { var r = request(opts, cb); r.end(); return r; }
        };
      }
      var httpShim = makeHttp("http");
      var httpsShim = makeHttp("https");

      var MODULES = {
        fs: fsShim, path: pathShim, "nw.gui": nwGuiShim,
        events: eventsShim, util: utilShim, assert: assertShim,
        http: httpShim, https: httpsShim, os: {
          platform: function () { return "ios"; }, EOL: "\n", homedir: function () { return "/"; },
          tmpdir: function () { return "/tmp"; }, hostname: function () { return "ios"; }
        }
      };

      window.require = function (m) {
        m = String(m);
        if (Object.prototype.hasOwnProperty.call(MODULES, m)) return MODULES[m];
        // Unknown module: return a benign empty object (so a top-level `require` doesn't crash
        // a mod that only conditionally uses it) but warn so the gap is debuggable.
        try { console.warn("[cc require] unshimmed module '" + m + "' → {} (some features may not work)"); } catch (e) {}
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

    /// Routes external (http/https) links to the native host so they open in the system
    /// browser. CrossCode/CCModManager open repo/author links with `window.open(url,"_blank")`
    /// in browser mode; in a WKWebView that needs a `WKUIDelegate` *and* a user gesture, and
    /// the gamepad-driven d-pad "visit" action is not a WebKit user gesture — so the popup is
    /// silently suppressed. We instead override `window.open` to post the URL straight to the
    /// `cccontrol` handler (no gesture/popup needed), which opens it via `UIApplication`.
    /// All frames, documentStart, so it's in place before CCLoader/CCModManager run.
    public static let externalLinkJavaScript: String = #"""
    (function () {
      "use strict";
      if (window.__ccLinkHookInstalled) return;
      window.__ccLinkHookInstalled = true;

      function openExternal(u) {
        try {
          var s = String(u);
          if (/^https?:\/\//i.test(s)) {
            window.webkit.messageHandlers.cccontrol.postMessage("link:" + s);
            return true;
          }
        } catch (e) {}
        return false;
      }
      window.__ccOpenExternal = openExternal;

      var origOpen = (typeof window.open === "function") ? window.open.bind(window) : null;
      window.open = function (u, name, features) {
        if (openExternal(u)) return null;            // external link → system browser
        return origOpen ? origOpen(u, name, features) : null;
      };
    })();
    """#

    /// documentStart `WKUserScript` (all frames) installing the external-link hook.
    public static func externalLinkUserScript() -> WKUserScript {
        WKUserScript(source: externalLinkJavaScript,
                     injectionTime: .atDocumentStart,
                     forMainFrameOnly: false)
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
    ///
    /// SEED ONCE PER BROWSING CONTEXT — NOT ON RELOADS. This payload is a SNAPSHOT of
    /// `Documents/cc.save` taken when the app launched. A `WKUserScript` re-runs on every
    /// page load, including in-app reloads — and the cc-ios "Restart Game" button
    /// (`ControlBridge` / the cc-iosux mod) and the cc-ultrawide restart prompt all
    /// `webView.reload()`. Re-running an unconditional `setItem` on reload would clobber
    /// `localStorage["cc.save"]` — the live save the player has been writing this session —
    /// with the stale launch-time snapshot, silently losing all progress since launch
    /// (manual + autosaves alike). That is a real, reported data-loss bug.
    ///
    /// `sessionStorage` is the exact signal we need: it survives a `location.reload()` /
    /// `webView.reload()` (same browsing context) but is cleared when the `WKWebView` is
    /// recreated on a genuine app relaunch. So we seed on the FIRST load of each launch
    /// (when `Documents/cc.save` is fresh — the save hook keeps it current, and any sync
    /// pull has just run) and skip every reload, leaving the live save intact. If the guard
    /// read ever throws we DON'T seed (fail safe: never clobber an existing save).
    public static func saveInjectionUserScript(base64Save: String) -> WKUserScript {
        let source = """
        (function () {
          try {
            if (window.sessionStorage.getItem("__ccSaveSeeded")) return; // reload → keep live save
            window.sessionStorage.setItem("__ccSaveSeeded", "1");
          } catch (e) { return; /* no sessionStorage → don't risk clobbering the live save */ }
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

    /// JS that measures the real frame rate via `requestAnimationFrame` (independent of the
    /// engine's target `ig.system.fps`) and posts it to the native host ~2×/sec as
    /// `{type:"fps", value:N}`. The counter itself is drawn by a **native** overlay
    /// (see `GameView`): on iOS the game's hardware-composited WebGL canvas paints above any
    /// in-page DOM element regardless of `z-index`, so an HTML overlay is invisible in-game —
    /// a native view above the `WKWebView` is the only reliable way to show it. Measures only
    /// in the top frame and re-arms on focus/visibility so backgrounding can't stall the loop.
    ///
    /// The counter is user-toggleable from the in-game mod manager (the `cc-iosux` mod adds a
    /// checkbox to CCModManager's "Mod settings", stored in `localStorage["cc-iosux-fpsCounter"]`).
    /// This script reads that flag each cycle and posts `{type:"fpsenabled", value:Bool}` when it
    /// flips so `GameView` can show/hide the native label; while disabled it stops reporting fps.
    public static let fpsOverlayJavaScript: String = #"""
    (function () {
      "use strict";
      if (window.__ccFpsInstalled) return;
      window.__ccFpsInstalled = true;
      // Only the top frame measures + reports (CCLoader runs the game in the main document).
      try { if (window !== window.top) return; } catch (e) {}

      var frames = 0, rafId = null;
      function nowMs() { return (performance && performance.now) ? performance.now() : Date.now(); }
      var last = nowMs();

      function report(fps) {
        try { window.webkit.messageHandlers.cchost.postMessage({ type: "fps", value: fps }); } catch (e) {}
      }

      // The FPS counter is user-toggleable from the in-game mod manager: the cc-iosux mod
      // registers a checkbox in CCModManager whose value is stored in localStorage under
      // "cc-iosux-fpsCounter" ("true"/"false"). Absent/null means the setting has not been
      // initialised yet, so we default to ON to preserve the historical always-on behaviour.
      // We re-read it each report cycle (cheap) and tell the native host to show/hide the
      // label only when the state changes; while disabled we also stop reporting fps.
      var FPS_SETTING_KEY = "cc-iosux-fpsCounter";
      function fpsEnabled() {
        try { return localStorage.getItem(FPS_SETTING_KEY) !== "false"; } catch (e) { return true; }
      }
      var lastEnabled = null;
      function reportEnabled(enabled) {
        try { window.webkit.messageHandlers.cchost.postMessage({ type: "fpsenabled", value: enabled }); } catch (e) {}
      }

      // Report the game canvas's left edge as a fraction of the viewport so the native FPS
      // label can sit just *outside* the canvas, in the black letterbox bar. Only posts when
      // it changes meaningfully (boot, rotation, resize).
      var lastLeftFrac = -1;
      function reportLayout() {
        try {
          var c = document.querySelector("#canvas, canvas");
          if (!c) return;
          var w = window.innerWidth || 1;
          var frac = c.getBoundingClientRect().left / w;
          if (frac < 0) frac = 0;
          if (Math.abs(frac - lastLeftFrac) > 0.004) {
            lastLeftFrac = frac;
            window.webkit.messageHandlers.cchost.postMessage({ type: "fpslayout", leftFrac: frac });
          }
        } catch (e) {}
      }

      function frame(now) {
        try {
          frames++;
          var dt = now - last;
          if (dt >= 500) {
            var enabled = fpsEnabled();
            if (enabled !== lastEnabled) { reportEnabled(enabled); lastEnabled = enabled; }
            if (enabled) {
              report(Math.round((frames * 1000) / dt));
              reportLayout();
            }
            frames = 0; last = now;
          }
        } catch (e) {}
        rafId = requestAnimationFrame(frame);
      }

      // iOS can drop the single in-flight requestAnimationFrame callback when the WebContent
      // process is suspended on backgrounding, permanently stalling this loop. Re-arm on
      // return-to-foreground: cancel any stale pending frame and start exactly one fresh loop.
      function kick() {
        if (rafId !== null) { try { cancelAnimationFrame(rafId); } catch (e) {} }
        last = nowMs();
        frames = 0;
        rafId = requestAnimationFrame(frame);
      }
      window.addEventListener("focus", kick, false);
      document.addEventListener("visibilitychange", function () {
        if (!document.hidden) kick();
      }, false);

      kick();
    })();
    """#

    /// documentEnd `WKUserScript` installing the FPS overlay (see ``fpsOverlayJavaScript``).
    public static func fpsOverlayUserScript() -> WKUserScript {
        WKUserScript(source: fpsOverlayJavaScript,
                     injectionTime: .atDocumentEnd,
                     forMainFrameOnly: false)
    }

    /// Web Audio unlock for iOS. A fresh `AudioContext` starts **suspended** on iOS and is
    /// only allowed to start rendering after a user gesture; until then CrossCode's sound
    /// effects (which use Web Audio) are silent even though the files decode fine, while
    /// background music keeps playing because it uses HTML5 `<audio>`. The engine already
    /// calls `context.resume()` in its update loop, but that call is rejected on iOS unless
    /// it follows a gesture. This script resumes CrossCode's context from the first real user
    /// gesture (and on focus/visibility), which is the standard iOS unlock.
    ///
    /// It deliberately does **not** replace the global `AudioContext` constructor — doing so
    /// destabilised the WebKit content process on device. It only reaches the engine's own
    /// context at `ig.soundManager.context.context`, and is a harmless no-op once that context
    /// is already running (e.g. on macOS, where contexts start unsuspended).
    public static let webAudioUnlockJavaScript: String = #"""
    (function () {
      "use strict";
      if (window.__ccAudioUnlockInstalled) return;
      window.__ccAudioUnlockInstalled = true;

      function gameCtx() {
        try {
          var wrap = window.ig && ig.soundManager && ig.soundManager.context;
          return (wrap && wrap.context) || null;
        } catch (e) { return null; }
      }

      // iOS uses a non-standard "interrupted" AudioContext state after the app is
      // backgrounded (the WebContent process's audio session is interrupted). Returning to
      // the foreground often leaves it "interrupted"/"suspended" with nothing resuming it —
      // which is why audio stayed dead until a full relaunch. Treat anything not "running"
      // as resumable (the old code only handled "suspended").
      function resumeNow() {
        var ctx = gameCtx();
        if (ctx && ctx.state !== "running" && ctx.resume) {
          try { ctx.resume(); } catch (e) {}
        }
      }

      // After returning from background the audio session needs a moment to reactivate
      // before resume() takes effect, so nudge it a few times until it's running.
      function resumeWithRetries() {
        resumeNow();
        var tries = 0;
        var id = setInterval(function () {
          resumeNow();
          var ctx = gameCtx();
          if (++tries >= 15 || (ctx && ctx.state === "running")) clearInterval(id);
        }, 200);
      }
      window.__ccResumeAudio = resumeWithRetries;

      var GESTURES = ["touchend", "touchstart", "pointerup", "pointerdown", "mousedown", "keydown", "click"];
      for (var g = 0; g < GESTURES.length; g++) {
        document.addEventListener(GESTURES[g], resumeNow, true);
      }
      window.addEventListener("focus", resumeWithRetries, false);
      document.addEventListener("visibilitychange", function () {
        if (!document.hidden) resumeWithRetries();
      }, false);
    })();
    """#

    /// documentEnd `WKUserScript` installing the Web Audio unlock (see ``webAudioUnlockJavaScript``).
    public static func webAudioUnlockUserScript() -> WKUserScript {
        WKUserScript(source: webAudioUnlockJavaScript,
                     injectionTime: .atDocumentEnd,
                     forMainFrameOnly: false)
    }
}
