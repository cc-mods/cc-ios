import Foundation
import GameController
import WebKit

/// Bridges a Bluetooth/MFi game controller into the WKWebView using Apple's GameController
/// framework, feeding the JS gamepad shim (`window.__ccpad`, see `Bootstrap`).
///
/// Why native rather than WebKit's own Gamepad API: CrossCode reads input via
/// `navigator.getGamepads()`, but iOS WebKit does not reliably expose Bluetooth controllers
/// to a page served from a custom URL scheme (and may demand an activation gesture). Reading
/// the controller natively via `GCController` and pushing state into the shim is deterministic
/// and gives us exact control over the W3C **standard mapping** CrossCode expects
/// (`buttons[0..15]`, `axes[0..3]`).
///
/// State is polled at 60 Hz but only forwarded to JS when it actually changes, so an idle
/// controller costs nothing and held inputs persist correctly.
final class ControllerBridge: NSObject {

    private weak var webView: WKWebView?
    private var pollTimer: Timer?
    private var lastPayload: String = ""
    private var connectedCount = 0

    func attach(to webView: WKWebView) {
        self.webView = webView
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didConnect),
                       name: .GCControllerDidConnect, object: nil)
        nc.addObserver(self, selector: #selector(didDisconnect),
                       name: .GCControllerDidDisconnect, object: nil)
        GCController.startWirelessControllerDiscovery(completionHandler: {})

        if !GCController.controllers().isEmpty {
            connectedCount = GCController.controllers().count
            notifyConnected()
            startPolling()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pollTimer?.invalidate()
    }

    @objc private func didConnect() {
        connectedCount = GCController.controllers().count
        NSLog("[cc pad] controller connected (%d total)", connectedCount)
        notifyConnected()
        startPolling()
    }

    @objc private func didDisconnect() {
        connectedCount = GCController.controllers().count
        NSLog("[cc pad] controller disconnected (%d remaining)", connectedCount)
        if connectedCount == 0 {
            stopPolling()
            lastPayload = ""
            webView?.evaluateJavaScript("window.__ccpad && window.__ccpad.disconnect();",
                                        completionHandler: nil)
        }
    }

    private func notifyConnected() {
        webView?.evaluateJavaScript("window.__ccpad && window.__ccpad.connect();",
                                    completionHandler: nil)
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self,
                          selector: #selector(poll), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func poll() {
        guard let gp = (GCController.current ?? GCController.controllers().first)?.extendedGamepad else {
            return
        }

        func v(_ b: GCControllerButtonInput?) -> Float { b?.value ?? 0 }
        // W3C standard mapping — must match ig.BUTTONS in game.compiled.js.
        let buttons: [Float] = [
            v(gp.buttonA), v(gp.buttonB), v(gp.buttonX), v(gp.buttonY),   // 0..3 FACE0..3
            v(gp.leftShoulder), v(gp.rightShoulder),                       // 4,5
            v(gp.leftTrigger), v(gp.rightTrigger),                         // 6,7
            v(gp.buttonOptions), v(gp.buttonMenu),                         // 8 SELECT, 9 START
            v(gp.leftThumbstickButton), v(gp.rightThumbstickButton),       // 10,11
            v(gp.dpad.up), v(gp.dpad.down), v(gp.dpad.left), v(gp.dpad.right), // 12..15
            v(gp.buttonHome)                                               // 16 (unused by game)
        ]
        // GameController y-axis is +1 up; the W3C standard gamepad axis is +1 down — invert.
        let axes: [Float] = [
            gp.leftThumbstick.xAxis.value, -gp.leftThumbstick.yAxis.value,
            gp.rightThumbstick.xAxis.value, -gp.rightThumbstick.yAxis.value
        ]

        let buttonsJSON = "[" + buttons.map { round3($0) }.joined(separator: ",") + "]"
        let axesJSON = "[" + axes.map { round3($0) }.joined(separator: ",") + "]"
        let payload = buttonsJSON + axesJSON
        guard payload != lastPayload else { return }   // only push on change
        lastPayload = payload

        webView?.evaluateJavaScript("window.__ccpad && window.__ccpad.update(\(buttonsJSON),\(axesJSON));",
                                    completionHandler: nil)
    }

    /// Round to 3 decimals to damp analog jitter and keep payloads stable/small.
    private func round3(_ f: Float) -> String {
        String(format: "%.3f", (f * 1000).rounded() / 1000)
    }
}
