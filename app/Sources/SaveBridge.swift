import Foundation
import WebKit

/// Persists CrossCode's save to a file in the app's Documents directory so it can be
/// synced with the desktop/Steam copy.
///
/// CrossCode (browser mode) keeps its entire save in `localStorage["cc.save"]`. That blob
/// is **byte-identical** to the desktop save file
/// (`~/Library/Application Support/CrossCode/Default/cc.save`), so syncing is just moving
/// the bytes. This bridge:
///
///   • **captures** every in-game save — the injected JS hook posts the new `cc.save`
///     string here, and we write it to `Documents/cc.save`;
///   • **restores** on launch — `initialSaveBase64()` reads `Documents/cc.save` so the
///     host can seed `localStorage` before the game boots.
///
/// The file is exposed via the Files app / Finder (`UIFileSharingEnabled`) and is the
/// artifact the desktop bridge (cc-tailsync's `save-sync.sh`, using `xcrun devicectl device copy`)
/// shuttles to and from the Steam save location.
final class SaveBridge: NSObject, WKScriptMessageHandler {

    /// `Documents/cc.save` — the synced save artifact.
    static var saveFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("cc.save")
    }

    /// Base64-encoded contents of the synced save file, or `nil` if none exists yet.
    /// Base64 keeps the 164 KB payload free of JS string-escaping hazards on injection.
    static func initialSaveBase64() -> String? {
        guard let data = try? Data(contentsOf: saveFileURL), !data.isEmpty else { return nil }
        return data.base64EncodedString()
    }

    /// Optional sink invoked with the raw save string whenever a save is written, so a
    /// network sync client can upload it. Set by the owner.
    var onSaveWritten: ((String) -> Void)?

    /// Receives the raw `cc.save` string from the JS hook and writes it to the file.
    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Bootstrap.saveMessageHandlerName,
              let value = message.body as? String else { return }
        write(value)
        onSaveWritten?(value)
    }

    /// If the file doesn't exist yet but `localStorage` already holds a save (e.g. a save
    /// made before this feature existed), capture it so the bridge has something to sync.
    func captureExistingIfNeeded(from webView: WKWebView) {
        guard !FileManager.default.fileExists(atPath: Self.saveFileURL.path) else { return }
        webView.evaluateJavaScript("localStorage.getItem('cc.save')") { [weak self] result, _ in
            if let value = result as? String { self?.write(value) }
        }
    }

    /// Imports an externally-supplied save (e.g. one the user dropped into the Files-app
    /// `saves/` folder) as the canonical save, so it becomes active on this launch.
    func importExternalSave(_ data: Data) {
        guard let value = String(data: data, encoding: .utf8) else {
            NSLog("[cc save] ignored non-UTF8 import (%d bytes)", data.count)
            return
        }
        write(value)
    }

    private func write(_ value: String) {
        let url = Self.saveFileURL
        guard let data = value.data(using: .utf8) else { return }
        do {
            try data.write(to: url, options: .atomic)
            // Keep the Files-app saves/ folder mirror in sync with the canonical save.
            SaveFolder.recordExport(data)
            NSLog("[cc save] wrote %d bytes to %@", data.count, url.path)
        } catch {
            NSLog("[cc save] failed to write save: %@", error.localizedDescription)
        }
    }
}
