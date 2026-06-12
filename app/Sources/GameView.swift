import SwiftUI
import WebKit
import AVFoundation
import UIKit

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
        webView.uiDelegate = context.coordinator
        // Native FPS overlay: drawn as a UILabel above the web view because the game's WebGL
        // canvas composites over any in-page DOM overlay on iOS (z-index can't beat it).
        context.coordinator.installFPSOverlay(on: webView)
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
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        private weak var webView: WKWebView?
        private weak var fpsLabel: UILabel?
        private var fpsTrailingConstraint: NSLayoutConstraint?
        let saveBridge = SaveBridge()
        let controllerBridge = ControllerBridge()
        let controlBridge = ControlBridge()
        let syncClient = SaveSyncClient()

        /// Adds a native FPS label on top of the web view. The JS overlay only *measures* the
        /// frame rate and posts it (see `Bootstrap.fpsOverlayJavaScript`); we draw it natively
        /// because the game's WebGL canvas composites above any in-page DOM element on iOS, so
        /// an HTML counter is invisible in-game. A UIKit subview of the WKWebView always paints
        /// above the web content.
        ///
        /// The game canvas is letterboxed (black bars left/right). We pin the label's *right*
        /// edge just left of the canvas — in that black bar — using a constraint whose constant
        /// the JS keeps updated with the canvas's measured left edge (`updateFPSLayout`).
        func installFPSOverlay(on webView: WKWebView) {
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
            label.textColor = UIColor(red: 124/255, green: 252/255, blue: 138/255, alpha: 1)
            label.backgroundColor = UIColor(white: 0, alpha: 0.55)
            label.textAlignment = .center
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
            label.isUserInteractionEnabled = false
            label.text = " -- "
            webView.addSubview(label)
            // Right edge sits this many points from the web view's left edge; updated once the
            // game reports its canvas position. Sensible default before the first report.
            let trailing = label.trailingAnchor.constraint(equalTo: webView.leadingAnchor, constant: 56)
            NSLayoutConstraint.activate([
                trailing,
                label.topAnchor.constraint(equalTo: webView.safeAreaLayoutGuide.topAnchor, constant: 6)
            ])
            fpsTrailingConstraint = trailing
            fpsLabel = label
        }

        /// Repositions the label just left of the game canvas. `leftFrac` is the canvas's left
        /// edge as a fraction of the viewport width (reported by JS, resolution-independent).
        /// The label's right edge sits a small gap left of the canvas, so the whole number is in
        /// the black letterbox bar. We use only a small fixed corner allowance — NOT the full
        /// `safeAreaInsets.left`, which is large because the Dynamic Island lives on that edge
        /// (vertically centered, not at the top corner where this label sits), and would shove
        /// the label into the game.
        private func updateFPSLayout(leftFrac: Double) {
            guard let webView = webView, let c = fpsTrailingConstraint else { return }
            let canvasLeft = webView.bounds.width * CGFloat(leftFrac)
            let cornerClear: CGFloat = 30        // keep the label clear of the rounded corner curve
            c.constant = max(canvasLeft - 6, cornerClear)   // 6pt gap left of the canvas
        }

        /// Updates the native FPS label (called from the `fps` script message). Shows just the
        /// number, colour-coded: green ≥55, amber ≥30, red below.
        private func updateFPS(_ fps: Int) {
            guard let label = fpsLabel else { return }
            label.text = " \(fps) "
            label.textColor = fps >= 55 ? UIColor(red: 124/255, green: 252/255, blue: 138/255, alpha: 1)
                : (fps >= 30 ? UIColor(red: 1, green: 0.82, blue: 0.29, alpha: 1)
                             : UIColor(red: 1, green: 0.42, blue: 0.42, alpha: 1))
        }

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
        /// CrossCode's Web Audio context is nested at `ig.soundManager.context.context`
        /// (the outer `.context` is the engine's wrapper), so resume must target that.
        private func dispatchWindowEvent(_ name: String) {
            let js = """
            (function(){
              try { window.dispatchEvent(new Event(\"\(name)\")); } catch (e) {}
              try {
                if (\"\(name)\" === "focus" && window.__ccResumeAudio) { window.__ccResumeAudio(); }
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
            case "fps":
                if let n = (dict["value"] as? NSNumber)?.intValue { updateFPS(n) }
            case "fpslayout":
                if let f = (dict["leftFrac"] as? NSNumber)?.doubleValue { updateFPSLayout(leftFrac: f) }
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

        /// The WebKit content process died (commonly an out-of-memory jetsam on device during
        /// the game's heavy asset/audio preload). The host app stays alive but the WebView
        /// goes blank — the "black screen" failure mode. Log it and reload so the game can
        /// recover instead of sitting on a black screen.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            NSLog("[cc CRASH] WebContent process terminated (likely OOM); reloading")
            webView.reload()
        }

        // MARK: - External links → system browser

        /// CrossCode and CCModManager open repo/author links with `window.open(url, "_blank")`
        /// in browser mode. In a WKWebView that asks the UI delegate to create a new web view;
        /// we don't host secondary web views, so route the URL to Safari and return nil (which
        /// is why these links did nothing before — there was no `WKUIDelegate`).
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { openExternally(url) }
            return nil
        }

        /// Also catch in-frame external link activations (e.g. an `<a href>` click): send
        /// http(s) link navigations to Safari and keep the game's own `ccgame://` loads (and
        /// any data:/blob:/about: navigations) in-view. Non-link/iframe loads are untouched.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https",
               navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
                openExternally(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// Opens a vetted http(s) URL in the system browser. Other schemes are ignored — the
        /// game's assets use the internal `ccgame://` scheme and must never leave the app.
        private func openExternally(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
            NSLog("[cc link] opening external URL: %@", url.absoluteString)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
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
