import Foundation
import WebKit
import UIKit

/// Handles title-screen control actions posted from the injected overlay buttons
/// (see `Bootstrap.controlsJavaScript` / the cc-iosux mod): **Restart** reloads the web view
/// (re-boots CrossCode/CCLoader from scratch), **Quit** terminates the app.
///
/// Both are *deliberate* exits the host fully controls, so — unlike the fire-and-forget save push on
/// every in-game save — we gate them on a **confirmed** save flush: show a brief "Saving…" overlay,
/// wait (bounded) for the sync provider to confirm the latest `cc.save` reached the hub, then
/// reload / terminate. This is the one place blocking on the network is legitimate, because *we* own
/// the termination. It is always bounded (a dead network can never trap the user in the app) and is a
/// no-op fast-path when no sync provider is wired or we're already in sync.
///
/// `exit(0)` is generally discouraged by Apple for App Store apps, but this is a personal
/// **sideloaded** build where an explicit "Close Game" is a reasonable convenience, so we honour it.
final class ControlBridge: NSObject, WKScriptMessageHandler {

    private weak var webView: WKWebView?
    private var savingOverlay: UIView?

    func attach(to webView: WKWebView) { self.webView = webView }

    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Bootstrap.controlMessageHandlerName,
              let action = message.body as? String else { return }

        // External links (CCModManager "visit repository/author") arrive as "link:<url>".
        if action.hasPrefix("link:") {
            let urlString = String(action.dropFirst("link:".count))
            guard let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            NSLog("[cc link] opening external URL: %@", url.absoluteString)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return
        }

        switch action {
        case "restart":
            // Reloading is already save-safe (the save lives on disk + in localStorage, and the
            // seed-once guard prevents clobbering), and the app stays alive afterward — so a confirmed
            // network round-trip buys no safety here and must not stall a frequently-used action.
            // Fire a best-effort push (instant no-op when already in sync) and reload immediately.
            NSLog("[cc control] restart")
            SaveSync.provider?.flush(timeout: 8) { _ in }
            reloadGame()
        case "quit":
            NSLog("[cc control] quit — confirming save before exit")
            flushSaveThenQuit()
        default:
            break
        }
    }

    // MARK: - Confirmed-save gate (Close Game)

    /// Confirm the latest save reached the hub, then terminate. Shows a "Saving…" overlay only if the
    /// flush takes a beat (no flash when already in sync / unconfigured). If the push can't be
    /// confirmed within the timeout (offline / flaky network), we DON'T pretend it synced: we ask the
    /// user whether to quit anyway (the save is safe on disk and reconciles next launch) — delivering
    /// the "good status before exit" they asked for instead of a silent, falsely-confident quit.
    private func flushSaveThenQuit() {
        guard let provider = SaveSync.provider else { Self.terminate(); return }

        // Defer the overlay slightly so the common (fast / in-sync) case shows nothing.
        let showOverlay = DispatchWorkItem { [weak self] in self?.showSavingOverlay() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: showOverlay)

        provider.flush(timeout: 10) { [weak self] confirmed in
            showOverlay.cancel()
            self?.hideSavingOverlay()
            if confirmed {
                Self.terminate()
            } else {
                NSLog("[cc control] save not confirmed within timeout — asking before exit")
                self?.presentQuitFailureAlert(onQuit: { Self.terminate() })
            }
        }
    }

    /// The push couldn't be confirmed (offline / timeout). Tell the user plainly and let them choose,
    /// rather than quitting on a false sense of success. Falls back to quitting if we can't present.
    private func presentQuitFailureAlert(onQuit: @escaping () -> Void) {
        guard let vc = webView?.window?.rootViewController else { onQuit(); return }
        let alert = UIAlertController(
            title: "Couldn't Confirm Cloud Save",
            message: "Your progress is saved on this device and will sync the next time you open the app. Quit now anyway?",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Quit Anyway", style: .destructive) { _ in onQuit() })
        alert.addAction(UIAlertAction(title: "Stay in Game", style: .cancel, handler: nil))
        vc.present(alert, animated: true)
    }

    private func reloadGame() {
        if let url = webView?.url {
            webView?.load(URLRequest(url: url))
        } else {
            webView?.reload()
        }
    }

    private static func terminate() {
        // Gracefully background (animates to the home screen via the private `suspend` selector —
        // acceptable for a personal sideloaded build) and then terminate.
        let app = UIApplication.shared
        let suspend = NSSelectorFromString("suspend")
        if app.responds(to: suspend) { app.perform(suspend) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
    }

    // MARK: - "Saving…" overlay

    private func showSavingOverlay() {
        guard savingOverlay == nil, let host = webView?.window ?? webView else { return }

        let overlay = UIView(frame: host.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor(white: 0, alpha: 0.55)

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(white: 0.1, alpha: 0.95)
        card.layer.cornerRadius = 12
        overlay.addSubview(card)

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        spinner.startAnimating()
        card.addSubview(spinner)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Saving…"
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        card.addSubview(label)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 160),
            card.heightAnchor.constraint(equalToConstant: 120),
            spinner.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: card.centerYAnchor, constant: -10),
            label.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
        ])

        host.addSubview(overlay)
        savingOverlay = overlay
    }

    private func hideSavingOverlay() {
        savingOverlay?.removeFromSuperview()
        savingOverlay = nil
    }
}
