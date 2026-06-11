import SwiftUI
import WebKit
import AVFoundation

/// Bridges the shared `CCWebHost` WKWebView into SwiftUI and locates the bundled game
/// assets. Assets ship as a folder reference named `game` inside the app bundle, so the
/// scheme handler reads them in-place — no sandbox copy required. Saves are written by
/// the game to `localStorage`, which WebKit persists per-origin automatically.
struct GameView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        guard let assetRoot = Self.bundledAssetRoot() else {
            return Self.errorView(message: """
            Game assets not found in app bundle.

            Expected a 'game' folder containing \(GameWebHost.entryPath).
            Run tools/sync-assets.sh before building to copy your local CrossCode
            assets into app/Resources/game.
            """)
        }

        // Files-app saves folder (Documents/saves): if the user dropped a replacement save
        // from a computer, import it so it becomes the active (and freshest) save before sync.
        SaveFolder.ensure()
        if let dropped = SaveFolder.pendingImport() {
            context.coordinator.saveBridge.importExternalSave(dropped)
            NSLog("[cc saves] imported %d bytes from the saves/ folder", dropped.count)
        }

        // Wireless sync (optional): if a server is configured, pull a newer save into
        // Documents/cc.save before we read it for injection. Bounded so launch stays snappy.
        _ = context.coordinator.syncClient.pullIfNewerBlocking(timeout: 4)

        // Mirror whatever save we ended up with into the saves/ folder so the latest is
        // always grabbable from a PC (and so our mirror matches the canonical save).
        if let data = try? Data(contentsOf: SaveBridge.saveFileURL), !data.isEmpty {
            SaveFolder.recordExport(data)
        }

        context.coordinator.saveBridge.onSaveWritten = { [weak coordinator = context.coordinator] value in
            coordinator?.syncClient.push(value)
        }

        let config = GameWebHost.makeConfiguration(
            assetRoot: assetRoot,
            messageHandler: context.coordinator,
            preferM4AAudio: true,
            saveHandler: context.coordinator.saveBridge,
            initialSaveBase64: SaveBridge.initialSaveBase64(),
            controlHandler: context.coordinator.controlBridge,
            modsOverlayRoot: Self.modsOverlayRoot(),
            showFPS: true,
            schemeLog: { line in NSLog("[ccfs] %@", line) }
        )

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // Do NOT set customUserAgent — the default WebKit UA reports navigator.vendor
        // "Apple", which makes CrossCode select its BROWSER code path (localStorage saves,
        // XHR asset loads, no Node fs).
        if #available(iOS 16.4, *) { webView.isInspectable = true }

        context.coordinator.attach(to: webView)
        webView.navigationDelegate = context.coordinator
        AudioSession.activate()
        UIApplication.shared.isIdleTimerDisabled = true

        webView.load(URLRequest(url: GameWebHost.entryURL(path: GameWebHost.resolveEntryPath(assetRoot: assetRoot))))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        UIApplication.shared.isIdleTimerDisabled = false
        AudioSession.deactivate()
    }

    /// Receives console/error/status messages posted by the bootstrap script, and owns
    /// the app-lifecycle wiring (pause/resume + audio), the controller bridge, and the
    /// save bridge for the hosted game.
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private weak var webView: WKWebView?
        let saveBridge = SaveBridge()
        let controllerBridge = ControllerBridge()
        let controlBridge = ControlBridge()
        let syncClient = SaveSyncClient()

        /// Connects the web view and registers for lifecycle + audio-interruption events.
        /// CrossCode pauses on a `blur` event and resumes on `focus`, so we forward the
        /// app's background/foreground transitions (and audio interruptions) to those.
        func attach(to webView: WKWebView) {
            self.webView = webView
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(didBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
            nc.addObserver(self, selector: #selector(willForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
            nc.addObserver(self, selector: #selector(audioInterruption),
                           name: AVAudioSession.interruptionNotification, object: nil)
            controllerBridge.attach(to: webView)
            controlBridge.attach(to: webView)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func didBackground() { dispatchWindowEvent("blur") }

        @objc private func willForeground() {
            AudioSession.activate()
            dispatchWindowEvent("focus")
        }

        @objc private func audioInterruption(_ note: Notification) {
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                dispatchWindowEvent("blur")
            case .ended:
                AudioSession.activate()
                dispatchWindowEvent("focus")
            @unknown default:
                break
            }
        }

        /// Dispatches a DOM event on `window` (e.g. focus/blur) to drive the game's own
        /// pause/resume logic, and nudges any suspended Web Audio context back to life.
        private func dispatchWindowEvent(_ name: String) {
            let js = """
            (function(){
              try { window.dispatchEvent(new Event(\"\(name)\")); } catch (e) {}
              try {
                var ctx = window.ig && ig.soundManager && ig.soundManager.context;
                if (ctx && ctx.state === "suspended" && \"\(name)\" === "focus") { ctx.resume(); }
              } catch (e) {}
            })();
            """
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        func userContentController(_ ucc: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any] else { return }
            let type = dict["type"] as? String ?? "?"
            let msg = dict["message"] as? String ?? ""
            switch type {
            case "error": NSLog("[cc JSERR] %@", msg)
            case "status": NSLog("[cc BOOT] %@", msg)
            default:
                let level = (dict["level"] as? String ?? "log").uppercased()
                NSLog("[cc JS:%@] %@", level, msg)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // If we have no synced save file yet but localStorage already holds one (e.g. a
            // save made before sync existed), capture it so the bridge has something to push.
            saveBridge.captureExistingIfNeeded(from: webView)
        }
    }

    // MARK: - Asset location

    /// Locates the bundled `game` folder reference. Supports both layouts: the plain game
    /// (root contains `node-webkit.html`) and the CCLoader overlay (root contains
    /// `ccloader/index.html`, with the game under `assets/`).
    static func bundledAssetRoot() -> URL? {
        let fm = FileManager.default
        if let root = Bundle.main.resourceURL?.appendingPathComponent("game") {
            let plain = root.appendingPathComponent(GameWebHost.entryPath)
            let ccloader = root.appendingPathComponent(GameWebHost.ccloaderEntryPath)
            if fm.fileExists(atPath: plain.path) || fm.fileExists(atPath: ccloader.path) {
                return root
            }
        }
        // Fallback: search the bundle for node-webkit.html in case the folder was
        // flattened by the resource copy.
        if let entry = Bundle.main.url(forResource: "node-webkit", withExtension: "html") {
            return entry.deletingLastPathComponent()
        }
        return nil
    }

    /// Writable directory for installed mods (`Documents/mods`), enabling CCModManager
    /// one-click installs. Returns nil when CCLoader isn't bundled (mod support only makes
    /// sense with the loader present), so the plain game build skips all the fs-shim wiring.
    static func modsOverlayRoot() -> URL? {
        guard let root = bundledAssetRoot() else { return nil }
        let ccloader = root.appendingPathComponent(GameWebHost.ccloaderEntryPath)
        guard FileManager.default.fileExists(atPath: ccloader.path) else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let mods = docs.appendingPathComponent("mods")
        try? FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
        return mods
    }

    static func errorView(message: String) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.backgroundColor = .black
        let html = """
        <html><body style="background:#111;color:#eee;font:16px -apple-system;padding:24px">
        <h2>cc-ios</h2><pre style="white-space:pre-wrap">\(message)</pre></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }
}
