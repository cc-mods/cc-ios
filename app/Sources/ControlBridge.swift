import Foundation
import WebKit
import UIKit

/// Handles title-screen control actions posted from the injected overlay buttons
/// (see `Bootstrap.controlsJavaScript`): **Restart** reloads the web view (re-boots
/// CrossCode/CCLoader from scratch), **Quit** terminates the app.
///
/// `exit(0)` is generally discouraged by Apple for App Store apps, but this is a
/// personal **sideloaded** build where an explicit "Close Game" is a reasonable
/// convenience, so we honour it.
final class ControlBridge: NSObject, WKScriptMessageHandler {

    private weak var webView: WKWebView?

    func attach(to webView: WKWebView) { self.webView = webView }

    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Bootstrap.controlMessageHandlerName,
              let action = message.body as? String else { return }
        switch action {
        case "restart":
            NSLog("[cc control] restart")
            if let url = webView?.url {
                webView?.load(URLRequest(url: url))
            } else {
                webView?.reload()
            }
        case "quit":
            NSLog("[cc control] quit")
            // Give a beat for any in-flight save push to start, then gracefully background
            // (animates to the home screen via the private `suspend` selector — acceptable
            // for a personal sideloaded build) and terminate.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let app = UIApplication.shared
                let suspend = NSSelectorFromString("suspend")
                if app.responds(to: suspend) { app.perform(suspend) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exit(0) }
            }
        default:
            break
        }
    }
}
