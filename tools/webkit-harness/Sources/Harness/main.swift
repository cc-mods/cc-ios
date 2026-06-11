import AppKit
import WebKit
import CCWebHost

// cc-ios macOS proof harness.
//
// Boots the real CrossCode assets in a WKWebView using the SAME CCWebHost layer the iOS
// app uses (custom-scheme file server + document-start NW.js neutralization bootstrap).
// Streams the page's console/errors to stdout, polls for `ig.ready`, and writes a PNG
// screenshot as proof that WebGL renders. Exits 0 on success, 1 on timeout/failure.
//
// Usage:
//   webkit-harness [--timeout SECONDS] [--out FILE.png] [--root DIR] [--keep-open]
//
// Asset root resolution order:
//   1. --root DIR
//   2. $CCIOS_ASSET_ROOT
//   3. tools/webkit-harness/asset-root.local  (first line = path; gitignored)
//   4. default Steam macOS location

// MARK: - Argument parsing

struct Options {
    var timeout: TimeInterval = 120
    var settle: TimeInterval = 0
    var outPath: String = "tools/webkit-harness/last-run.png"
    var explicitRoot: String?
    var keepOpen = false
    var frames = 0
    var interval: TimeInterval = 3
    var outDir = "tools/webkit-harness/frames"
    var poke = false
    var lsSet: String?
    var lsSetFile: String?
    var lsGet = false
    var lsClear = false
    var lsKey = "ccios.probe"
    var evalAfterReady: String?
    var preferM4A = false
    var entry = GameWebHost.entryPath
    var modsOverlay: String?
    var showFPS = false
}

func parseOptions() -> Options {
    var opts = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--timeout": if let v = it.next(), let t = TimeInterval(v) { opts.timeout = t }
        case "--settle":  if let v = it.next(), let t = TimeInterval(v) { opts.settle = t }
        case "--out":     if let v = it.next() { opts.outPath = v }
        case "--root":    if let v = it.next() { opts.explicitRoot = v }
        case "--keep-open": opts.keepOpen = true
        case "--frames":  if let v = it.next(), let n = Int(v) { opts.frames = n }
        case "--interval": if let v = it.next(), let t = TimeInterval(v) { opts.interval = t }
        case "--outdir":  if let v = it.next() { opts.outDir = v }
        case "--poke":    opts.poke = true
        case "--ls-set":  if let v = it.next() { opts.lsSet = v }
        case "--ls-set-file": if let v = it.next() { opts.lsSetFile = v }
        case "--ls-get":  opts.lsGet = true
        case "--ls-clear": opts.lsClear = true
        case "--ls-key":  if let v = it.next() { opts.lsKey = v }
        case "--eval":    if let v = it.next() { opts.evalAfterReady = v }
        case "--prefer-m4a": opts.preferM4A = true
        case "--entry":   if let v = it.next() { opts.entry = v }
        case "--mods-overlay": if let v = it.next() { opts.modsOverlay = v }
        case "--fps":     opts.showFPS = true
        case "-h", "--help":
            print("""
            webkit-harness — boot CrossCode in WKWebView and prove it renders.
              --timeout SECONDS   max time to wait for ig.ready (default 120)
              --settle SECONDS    wait this long after ig.ready before screenshot
              --out FILE.png      screenshot output path
              --root DIR          asset root (app.nw/assets); overrides env/local/default
              --frames N          after ready, capture N filmstrip frames
              --interval SECONDS  seconds between filmstrip frames (default 3)
              --outdir DIR        filmstrip output directory
              --poke              dispatch synthetic click + Enter to advance past splash
              --ls-set VALUE      write localStorage[--ls-key]=VALUE then exit (persistence test)
              --ls-set-file FILE  write localStorage[--ls-key]=contents of FILE then exit (save import)
              --ls-get            read localStorage[--ls-key], print it, exit 0 if present
              --ls-clear          remove localStorage[--ls-key] then exit
              --ls-key KEY        localStorage key for --ls-* (default ccios.probe)
              --eval JS           after ig.ready, evaluate JS, print the result, exit
              --prefer-m4a        patch the game to prefer M4A audio (iOS path; needs .m4a media)
              --entry PATH        entry document relative to root (default node-webkit.html;
                                  use ccloader/index.html for CCLoader)
              --mods-overlay DIR  writable mods dir (enables CCModManager installs + fs shim)
              --fps               show a live FPS counter (top-right)
              --keep-open         leave the window open after success (manual inspection)
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("warning: ignoring unknown arg \(arg)\n".utf8))
        }
    }
    return opts
}

func resolveAssetRoot(_ opts: Options) -> URL? {
    let fm = FileManager.default
    func validate(_ path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let entry = url.appendingPathComponent(opts.entry)
        return fm.fileExists(atPath: entry.path) ? url : nil
    }

    // An explicit --root is authoritative: use it as-is (don't silently fall back to the
    // Steam dir, which would mask a wrong path), warning if the entry isn't found there.
    if let r = opts.explicitRoot {
        let expanded = (r as NSString).expandingTildeInPath
        if validate(r) == nil {
            FileHandle.standardError.write(Data(
                "warning: --root \(expanded) has no \(opts.entry); using it anyway\n".utf8))
        }
        return URL(fileURLWithPath: expanded)
    }

    if let env = ProcessInfo.processInfo.environment["CCIOS_ASSET_ROOT"], let url = validate(env) { return url }

    let localFile = URL(fileURLWithPath: "tools/webkit-harness/asset-root.local")
    if let contents = try? String(contentsOf: localFile, encoding: .utf8) {
        let first = contents.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !first.isEmpty, let url = validate(first) { return url }
    }

    let home = fm.homeDirectoryForCurrentUser.path
    let steamDefault = "\(home)/Library/Application Support/Steam/steamapps/common/CrossCode/CrossCode.app/Contents/Resources/app.nw/assets"
    if let url = validate(steamDefault) { return url }

    return nil
}

// MARK: - Logging

let startTime = Date()
func elapsed() -> String { String(format: "%6.1fs", Date().timeIntervalSince(startTime)) }
func emit(_ tag: String, _ message: String) {
    print("[\(elapsed())] \(tag) \(message)")
    fflush(stdout)
}

/// Encodes a Swift string as a safe JS string literal (with surrounding quotes).
func jsString(_ s: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [s])
    if let data = data, let arr = String(data: data, encoding: .utf8) {
        // arr is like ["value"]; strip the brackets to get the quoted literal.
        return String(arr.dropFirst().dropLast())
    }
    return "\"\""
}

// MARK: - App

final class Harness: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSApplicationDelegate {
    let opts: Options
    let assetRoot: URL
    var window: NSWindow!
    var webView: WKWebView!
    var pollTimer: Timer?
    var deadline: Timer?
    var finished = false
    var sawBootstrap = false
    var reportedPlatform: String?
    var errorCount = 0
    var notFoundCount = 0

    init(opts: Options, assetRoot: URL) {
        self.opts = opts
        self.assetRoot = assetRoot
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        emit("INFO", "asset root: \(assetRoot.path)")

        let config = GameWebHost.makeConfiguration(
            assetRoot: assetRoot,
            messageHandler: self,
            preferM4AAudio: opts.preferM4A,
            modsOverlayRoot: opts.modsOverlay.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            showFPS: opts.showFPS,
            schemeLog: { [weak self] line in
                if line.hasPrefix("404") { self?.notFoundCount += 1 }
                emit("HTTP", line)
            }
        )

        let frame = NSRect(x: 0, y: 0, width: 1136, height: 640)
        webView = WKWebView(frame: frame, configuration: config)
        webView.navigationDelegate = self
        // IMPORTANT: do NOT set a custom user agent — the default WebKit UA has
        // navigator.vendor "Apple", which makes CrossCode resolve to BROWSER mode.

        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "cc-ios harness"
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        emit("INFO", "loading \(GameWebHost.entryURL(path: opts.entry).absoluteString)")
        webView.load(URLRequest(url: GameWebHost.entryURL(path: opts.entry)))

        deadline = Timer.scheduledTimer(withTimeInterval: opts.timeout, repeats: false) { [weak self] _ in
            self?.finish(success: false, reason: "timeout after \(Int(self?.opts.timeout ?? 0))s")
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    // MARK: console bridge

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        let type = dict["type"] as? String ?? "?"
        let msg = dict["message"] as? String ?? ""
        switch type {
        case "status":
            if msg == "bootstrap-installed" { sawBootstrap = true }
            emit("BOOT", msg)
        case "error":
            errorCount += 1
            emit("JSERR", msg)
        case "console":
            let level = (dict["level"] as? String ?? "log").uppercased()
            emit("JS:\(level)", msg)
        default:
            emit("JS", "\(type) \(msg)")
        }
    }

    // MARK: navigation

    func webView(_ webView: WKWebView, didFailProvisional navigation: WKNavigation!, withError error: Error) {}
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        emit("NAVERR", error.localizedDescription)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        emit("INFO", "main document loaded")
        // Storage probes operate on localStorage directly and must NOT wait for ig.ready
        // (a corrupt save can block boot). Run shortly after the document is live.
        if opts.lsSet != nil || opts.lsSetFile != nil || opts.lsGet || opts.lsClear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.runStorageProbe()
            }
        }
    }

    /// Reads/writes/clears a single localStorage key and exits. Used to verify that the
    /// `ccgame://` origin persists storage across separate app launches — i.e. that
    /// CrossCode's `cc.save` survives, which is the entire M3 (saves) question on iOS.
    func runStorageProbe() {
        guard !finished else { return }
        finished = true
        pollTimer?.invalidate()
        deadline?.invalidate()
        let lsKey = opts.lsKey

        // Resolve the value to write: inline (--ls-set) or file contents (--ls-set-file).
        var setValue: String? = opts.lsSet
        if let file = opts.lsSetFile {
            do {
                setValue = try String(contentsOfFile: (file as NSString).expandingTildeInPath, encoding: .utf8)
            } catch {
                emit("LSSET", "error reading \(file): \(error.localizedDescription)"); exit(1)
            }
        }

        if let value = setValue {
            let js = "localStorage.setItem(\(jsString(lsKey)), \(jsString(value))); localStorage.getItem(\(jsString(lsKey))).length;"
            webView.evaluateJavaScript(js) { result, error in
                if let err = error { emit("LSSET", "error: \(err.localizedDescription)"); exit(1) }
                emit("LSSET", "\(lsKey) written, \(result as? Int ?? -1) chars stored")
                exit(0)
            }
        } else if opts.lsClear {
            let js = "localStorage.removeItem(\(jsString(lsKey))); localStorage.getItem(\(jsString(lsKey)));"
            webView.evaluateJavaScript(js) { result, _ in
                emit("LSCLEAR", "\(lsKey) removed (now \(result as? String ?? "nil"))")
                exit(0)
            }
        } else { // lsGet
            let js = "localStorage.getItem(\(jsString(lsKey)));"
            webView.evaluateJavaScript(js) { result, _ in
                if let value = result as? String {
                    emit("LSGET", "\(lsKey)=\(value)  (PERSISTED)")
                    exit(0)
                } else {
                    emit("LSGET", "\(lsKey)=<nil>  (NOT persisted)")
                    exit(1)
                }
            }
        }
    }

    // MARK: readiness polling

    let probe = #"""
    (function () {
      try {
        var hasIg = (typeof ig !== "undefined");
        var canvas = document.getElementById("canvas");
        return JSON.stringify({
          hasIg: hasIg,
          platform: (hasIg && ig.getPlatformName) ? ig.getPlatformName() : null,
          ready: hasIg ? !!ig.ready : false,
          os: (hasIg && ig.OS) ? ig.OS : null,
          browser: (hasIg && ig.browser) ? ig.browser : null,
          canvasW: canvas ? canvas.width : 0,
          canvasH: canvas ? canvas.height : 0,
          loadCount: (hasIg && ig.resources) ? ig.resources.length : null,
          start: typeof window.startCrossCode
        });
      } catch (e) { return JSON.stringify({ probeError: String(e) }); }
    })();
    """#

    func poll() {
        webView.evaluateJavaScript(probe) { [weak self] result, _ in
            guard let self = self else { return }
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            if let platform = obj["platform"] as? String, platform != self.reportedPlatform {
                self.reportedPlatform = platform
                let os = obj["os"] as? String ?? "?"
                let browser = obj["browser"] as? String ?? "?"
                emit("STATE", "platform=\(platform) os=\(os) browser=\(browser)")
            }
            let ready = obj["ready"] as? Bool ?? false
            let cw = obj["canvasW"] as? Int ?? 0
            let ch = obj["canvasH"] as? Int ?? 0
            emit("POLL", "ig=\(obj["hasIg"] as? Bool ?? false) ready=\(ready) canvas=\(cw)x\(ch)")
            if ready && cw > 0 && ch > 0 {
                self.finish(success: true, reason: "ig.ready with \(cw)x\(ch) canvas")
            }
        }
    }

    // MARK: finish

    func finish(success: Bool, reason: String) {
        guard !finished else { return }
        finished = true
        pollTimer?.invalidate()
        deadline?.invalidate()
        emit(success ? "PASS" : "FAIL", reason)
        emit("INFO", "bootstrap=\(sawBootstrap) platform=\(reportedPlatform ?? "?") jsErrors=\(errorCount) http404=\(notFoundCount)")

        guard success else {
            snapshot(to: opts.outPath) { exit(1) }
            return
        }

        // Optional: evaluate arbitrary JS against the booted game and print the result.
        if let expr = opts.evalAfterReady {
            webView.evaluateJavaScript(expr) { result, error in
                if let error = error {
                    emit("EVAL", "error: \(error.localizedDescription)"); exit(1)
                }
                emit("EVAL", "\(result.map { String(describing: $0) } ?? "nil")")
                // If a settle window is requested, stay alive so asynchronous work kicked
                // off by the eval (e.g. decodeAudioData callbacks) can flush via console.log
                // before we exit. Otherwise exit immediately as before.
                if self.opts.settle > 0 {
                    emit("INFO", "eval done; waiting \(Int(self.opts.settle))s for async logs…")
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.opts.settle) { exit(0) }
                } else {
                    exit(0)
                }
            }
            return
        }

        // Optional: dispatch synthetic input to advance past the splash/title.
        if opts.poke { poke() }

        // Optionally let the title screen settle/animate in before the primary capture.
        if opts.settle > 0 { emit("INFO", "settling \(Int(opts.settle))s before screenshot…") }
        DispatchQueue.main.asyncAfter(deadline: .now() + opts.settle) { [weak self] in
            guard let self = self else { return }
            self.snapshot(to: self.opts.outPath) {
                if self.opts.frames > 0 {
                    self.captureFilmstrip(remaining: self.opts.frames, index: 1)
                } else {
                    self.finishAfterCapture()
                }
            }
        }
    }

    func finishAfterCapture() {
        if opts.keepOpen {
            emit("INFO", "success; window left open (--keep-open). Ctrl-C to quit.")
        } else {
            exit(0)
        }
    }

    /// Dispatches a synthetic click on the canvas plus an Enter keypress — enough to get
    /// CrossCode past its title/“press start” gate so later frames show the menu.
    func poke() {
        let js = #"""
        (function () {
          try {
            var c = document.getElementById("canvas") || document.body;
            var r = c.getBoundingClientRect();
            var x = r.left + r.width / 2, y = r.top + r.height / 2;
            ["mousedown","mouseup","click"].forEach(function (t) {
              c.dispatchEvent(new MouseEvent(t, {bubbles:true,cancelable:true,clientX:x,clientY:y,button:0}));
            });
            [13, 32].forEach(function (code) {
              ["keydown","keyup"].forEach(function (t) {
                document.dispatchEvent(new KeyboardEvent(t, {bubbles:true,cancelable:true,keyCode:code,which:code,key:(code===13?"Enter":" ")}));
              });
            });
            return "poked";
          } catch (e) { return "poke-error: " + e; }
        })();
        """#
        webView.evaluateJavaScript(js) { result, _ in
            emit("POKE", (result as? String) ?? "?")
        }
    }

    func captureFilmstrip(remaining: Int, index: Int) {
        guard remaining > 0 else { finishAfterCapture(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + opts.interval) { [weak self] in
            guard let self = self else { return }
            let path = "\(self.opts.outDir)/frame-\(String(format: "%02d", index)).png"
            self.snapshot(to: path) {
                self.captureFilmstrip(remaining: remaining - 1, index: index + 1)
            }
        }
    }

    func snapshot(to path: String, _ done: @escaping () -> Void) {
        let cfg = WKSnapshotConfiguration()
        webView.takeSnapshot(with: cfg) { image, error in
            if let image = image, let png = Self.png(from: image) {
                let outURL = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(
                    at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try png.write(to: outURL)
                    emit("SHOT", "wrote \(outURL.path) (\(png.count) bytes)")
                } catch {
                    emit("SHOT", "failed to write screenshot: \(error.localizedDescription)")
                }
            } else {
                emit("SHOT", "snapshot unavailable: \(error?.localizedDescription ?? "no image")")
            }
            done()
        }
    }

    static func png(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - main

let opts = parseOptions()
guard let assetRoot = resolveAssetRoot(opts) else {
    FileHandle.standardError.write(Data("""
    error: could not locate CrossCode assets.
    Provide one of:
      --root /path/to/app.nw/assets
      CCIOS_ASSET_ROOT=/path/to/app.nw/assets
      tools/webkit-harness/asset-root.local  (first line = path)
    The directory must contain \(GameWebHost.entryPath).\n
    """.utf8))
    exit(2)
}

let app = NSApplication.shared
let harness = Harness(opts: opts, assetRoot: assetRoot)
app.delegate = harness
app.setActivationPolicy(.regular)
app.run()
