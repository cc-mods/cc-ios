import Foundation
import CommonCrypto

/// A user-facing `Documents/saves/` folder — visible in the Files app, the Finder, and
/// Windows (Apple Devices app / iTunes "File Sharing") — for backing up and restoring the
/// CrossCode save from a computer. It is the save-side analog of the `Documents/mods/`
/// overlay: a plain folder the user can read from and write to.
///
/// It mirrors the canonical `Documents/cc.save`:
///   • **export** — after any save the current bytes are written here as `cc.save`, so the
///     latest save can always be copied off the device;
///   • **import** — if the user replaces `saves/cc.save` from a computer, the change is
///     detected by content hash (so our own mirror is never mistaken for a drop) and the
///     replacement is imported on the next launch.
///
/// Conflict resolution stays the single project-wide rule: **newest save wins** (by mtime),
/// across the local file, the Tailscale server, and this folder. A file freshly copied in
/// from a PC has a current mtime, so a deliberate drop is picked up on the next launch.
enum SaveFolder {

    static var folderURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("saves", isDirectory: true)
    }

    /// `Documents/saves/cc.save` — the export mirror and import drop-zone.
    static var saveFileURL: URL { folderURL.appendingPathComponent("cc.save") }

    private static var readmeURL: URL { folderURL.appendingPathComponent("README.txt") }
    private static let exportHashKey = "ccSavesFolderExportedSHA"

    /// Creates the folder (and drops a short README the first time) so it shows up in Files
    /// even before the first save exists.
    static func ensure() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: readmeURL.path) {
            try? readmeText.data(using: .utf8)?.write(to: readmeURL, options: .atomic)
        }
    }

    /// If `saves/cc.save` exists and differs from what we last exported, the user replaced
    /// it from a computer → return its bytes to import. Otherwise `nil` (it's just our own
    /// mirror, or there's nothing there).
    static func pendingImport() -> Data? {
        guard let data = try? Data(contentsOf: saveFileURL), !data.isEmpty else { return nil }
        let lastExported = UserDefaults.standard.string(forKey: exportHashKey)
        return sha256(data) == lastExported ? nil : data
    }

    /// Mirrors the canonical save into the folder and remembers its hash, so this export is
    /// not later mistaken for a user import.
    static func recordExport(_ data: Data) {
        guard !data.isEmpty else { return }
        ensure()
        do {
            try data.write(to: saveFileURL, options: .atomic)
            UserDefaults.standard.set(sha256(data), forKey: exportHashKey)
        } catch {
            NSLog("[cc saves] export to folder failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func sha256(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static let readmeText = """
    CrossCode saves — cc-ios
    ========================

    This folder lets you back up and restore your CrossCode save from a computer:
      • Mac:      Finder → [your iPhone] → Files → cc-ios → saves
      • Windows:  Apple Devices app (or iTunes) → File Sharing → cc-ios
      • iPhone:   Files app → On My iPhone → cc-ios → saves

      cc.save   ← your current save. It updates automatically as you play.

    To BACK UP:  copy cc.save somewhere safe.
    To RESTORE:  replace cc.save with a backup (or a desktop CrossCode save) and
                 relaunch cc-ios. The newest save always wins, so a fresh copy from
                 your computer is picked up on the next launch.

    This file is byte-identical to the desktop CrossCode save
    (Steam: .../steamapps/common/CrossCode/.../CrossCode/Default/cc.save), so saves
    move directly between this device and the desktop game.
    """
}
