import Foundation
import WebKit

/// Cross-platform (iOS + macOS) factory that wires up a `WKWebView` configured to host
/// CrossCode: the custom-scheme file server, the document-start bootstrap, the console
/// bridge, and the entry URL. Both the macOS proof harness and the iOS app build their
/// web view from here so the behaviour is identical.
public enum GameWebHost {

    /// Storage key to retain the `ModFSBridge` for the content controller's lifetime.
    fileprivate static var fsBridgeKey: UInt8 = 0

    /// The game's default entry document, relative to the asset root. CCLoader changes
    /// this to `ccloader/index.html`; use ``entryURL(path:)`` to override.
    public static let entryPath = "node-webkit.html"

    /// Fully-qualified entry URL on the custom scheme for the given relative path.
    public static func entryURL(path: String = entryPath) -> URL {
        URL(string: "\(GameSchemeHandler.scheme)://game/\(path)")!
    }

    /// CCLoader's entry document, relative to the asset root.
    public static let ccloaderEntryPath = "ccloader/index.html"

    /// Picks the entry document for a given bundled asset root: if CCLoader has been
    /// overlaid (its `ccloader/index.html` is present), boot through it so mods load;
    /// otherwise boot the game directly. Lets one app binary support both layouts.
    public static func resolveEntryPath(assetRoot: URL) -> String {
        let ccloader = assetRoot.appendingPathComponent(ccloaderEntryPath)
        if FileManager.default.fileExists(atPath: ccloader.path) {
            return ccloaderEntryPath
        }
        return entryPath
    }

    /// Builds a `WKWebViewConfiguration` ready to load ``entryURL()``.
    ///
    /// - Parameters:
    ///   - assetRoot: Directory mapped to the web root (the `app.nw/assets` folder, or a
    ///     copy of it inside the app sandbox).
    ///   - messageHandler: Receives `{type, level, message}` dictionaries posted by the
    ///     bootstrap (console lines, errors, status).
    ///   - saveHandler: Optional handler receiving the raw `cc.save` string whenever the
    ///     game writes its save. Register one to mirror saves to a file for syncing.
    ///   - initialSaveBase64: Optional base64-encoded `cc.save` to seed `localStorage`
    ///     with at boot (a previously-synced save from the desktop/Steam copy).
    ///   - controlHandler: Optional handler for title-screen control buttons (restart/quit).
    ///     When provided, the overlay is injected and taps route here.
    ///   - modsOverlayRoot: Optional writable directory (e.g. `Documents/mods`) that enables
    ///     CCModManager one-click installs: serves installed mods on top of the bundle, forces
    ///     BROWSER platform, and exposes a `require("fs")` shim backed by a native bridge.
    ///   - schemeLog: Optional diagnostics sink for the scheme handler (404s, etc.).
    public static func makeConfiguration(
        assetRoot: URL,
        messageHandler: WKScriptMessageHandler,
        preferM4AAudio: Bool = false,
        saveHandler: WKScriptMessageHandler? = nil,
        initialSaveBase64: String? = nil,
        controlHandler: WKScriptMessageHandler? = nil,
        modsOverlayRoot: URL? = nil,
        showFPS: Bool = false,
        schemeLog: @escaping (String) -> Void = { _ in }
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()

        let modSupport = modsOverlayRoot != nil
        let handler = GameSchemeHandler(root: assetRoot,
                                        preferM4AAudio: preferM4AAudio,
                                        forceBrowserPlatform: modSupport,
                                        overlayRoot: modsOverlayRoot,
                                        log: schemeLog)
        configuration.setURLSchemeHandler(handler, forURLScheme: GameSchemeHandler.scheme)

        let controller = WKUserContentController()
        // Inject a synced save BEFORE the bootstrap/game scripts so it's present on first read.
        if let base64 = initialSaveBase64, !base64.isEmpty {
            controller.addUserScript(Bootstrap.saveInjectionUserScript(base64Save: base64))
        }
        // The fs/require shim must be present before CCLoader plugins evaluate.
        if modSupport, #available(iOS 14.0, macOS 11.0, *) {
            controller.addUserScript(Bootstrap.fsShimUserScript())
        }
        // External (http/https) links → system browser (CCModManager repo/author links).
        controller.addUserScript(Bootstrap.externalLinkUserScript())
        controller.addUserScript(Bootstrap.userScript())
        // Gamepad shim: backs navigator.getGamepads() with a native-fed virtual pad.
        controller.addUserScript(Bootstrap.gamepadShimUserScript())
        // iOS Web Audio unlock: resume the (initially suspended) AudioContext on the first
        // user gesture so sound effects play, not just the HTML5-audio background music.
        controller.addUserScript(Bootstrap.webAudioUnlockUserScript())
        if showFPS {
            controller.addUserScript(Bootstrap.fpsOverlayUserScript())
        }
        controller.add(messageHandler, name: Bootstrap.messageHandlerName)
        if let saveHandler = saveHandler {
            controller.add(saveHandler, name: Bootstrap.saveMessageHandlerName)
        }
        if let controlHandler = controlHandler {
            // The native control handler (restart/quit) is driven by the cc-iosux mod's
            // title buttons, which post to `cccontrol`. No HTML overlay is injected.
            controller.add(controlHandler, name: Bootstrap.controlMessageHandlerName)
        }
        if let modsOverlayRoot = modsOverlayRoot, #available(iOS 14.0, macOS 11.0, *) {
            let fsBridge = ModFSBridge(writableRoot: modsOverlayRoot, log: schemeLog)
            controller.addScriptMessageHandler(fsBridge, contentWorld: .page,
                                               name: Bootstrap.fsMessageHandlerName)
            // Keep the bridge alive for the controller's lifetime.
            objc_setAssociatedObject(controller, &Self.fsBridgeKey, fsBridge, .OBJC_ASSOCIATION_RETAIN)
        }
        configuration.userContentController = controller

        // The game manages its own audio start; allow it to play without a user gesture
        // so boot music/sfx aren't blocked during automated validation.
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // CrossCode renders into a fixed-size canvas and scales itself; stop WebKit from
        // doing its own viewport zooming on iOS.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif

        // Enable WebGL / developer affordances where the API exists.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        return configuration
    }
}
