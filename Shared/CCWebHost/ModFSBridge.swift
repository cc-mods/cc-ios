import Foundation
import WebKit

/// Native backing for the JS `fs` shim (`Bootstrap.fsShimJavaScript`). Implements the async
/// filesystem operations CCModManager needs to install mods, writing into a single writable
/// directory (the `Documents/mods` overlay). All paths from the page are interpreted relative
/// to that overlay's parent so that a write to `assets/mods/<id>.ccmod` lands in the overlay.
///
/// Uses `WKScriptMessageHandlerWithReply` so the page's `fs.promises.*` calls get real async
/// results. Every path is confined to the writable root (traversal-guarded).
@available(iOS 14.0, macOS 11.0, *)
public final class ModFSBridge: NSObject, WKScriptMessageHandlerWithReply {

    /// Writable overlay base. Web paths are appended directly (e.g. web
    /// `assets/mods/foo.ccmod` → `<base>/assets/mods/foo.ccmod`), matching how the scheme
    /// handler's read overlay resolves them, so writes and reads stay consistent.
    private let base: URL
    private let writablePrefixes: [String]
    private let log: (String) -> Void

    /// - Parameters:
    ///   - writableRoot: Overlay base directory (e.g. `Documents/ccmods`). Installed mods
    ///     land at `<base>/assets/mods/<id>/…` and CCModManager's cache at
    ///     `<base>/assets/mod-data/…`.
    ///   - webModsPrefix: Unused legacy parameter (kept for call-site compatibility).
    public init(writableRoot: URL, webModsPrefix: String = "assets/mods",
                log: @escaping (String) -> Void = { _ in }) {
        self.base = writableRoot.standardizedFileURL
        self.writablePrefixes = ["assets/mods", "assets/mod-data"]
        self.log = log
        super.init()
        try? FileManager.default.createDirectory(at: self.base,
                                                 withIntermediateDirectories: true)
    }

    /// Maps a web-relative path to a file under the overlay base by direct append, confined
    /// to the writable prefixes (mods + mod-data) and guarded against traversal.
    private func resolve(_ webPath: String) -> URL? {
        var p = webPath.replacingOccurrences(of: "\\", with: "/")
        while p.hasPrefix("./") { p.removeFirst(2) }
        while p.hasPrefix("/") { p.removeFirst() }
        guard writablePrefixes.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) else {
            return nil   // only the mod + mod-data trees are writable
        }
        let url = base.appendingPathComponent(p).standardizedFileURL
        guard url.path == base.path || url.path.hasPrefix(base.path + "/") else { return nil }
        return url
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let op = body["op"] as? String,
              let path = body["path"] as? String else {
            replyHandler(nil, "bad request"); return
        }
        guard let url = resolve(path) else {
            replyHandler(nil, "path not writable: \(path)"); return
        }
        let fm = FileManager.default

        switch op {
        case "writeFile":
            guard let b64 = body["dataB64"] as? String, let data = Data(base64Encoded: b64) else {
                replyHandler(nil, "bad data"); return
            }
            // CCModManager installs packed `.ccmod` archives. CCLoader's browser mode can't
            // read inside a packed mod (that needs the NW.js X-Cmd server protocol), so we
            // unzip into a folder mod, which browser mode loads natively via mods.json.
            if url.pathExtension.lowercased() == "ccmod" {
                let modDir = url.deletingPathExtension()
                try? fm.removeItem(at: modDir)
                if ZipReader.unzip(data, to: modDir) {
                    log("fs.writeFile \(path) → unpacked to \(modDir.lastPathComponent)/ (\(data.count) bytes)")
                    replyHandler(nil, nil)
                } else {
                    // Fall back to storing the raw archive if it isn't a valid zip.
                    do {
                        try fm.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
                        try data.write(to: url, options: .atomic)
                        replyHandler(nil, nil)
                    } catch { replyHandler(nil, "writeFile: \(error.localizedDescription)") }
                }
                return
            }
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                log("fs.writeFile \(path) (\(data.count) bytes)")
                replyHandler(nil, nil)
            } catch { replyHandler(nil, "writeFile: \(error.localizedDescription)") }

        case "readFile":
            guard let data = try? Data(contentsOf: url) else { replyHandler(nil, "ENOENT"); return }
            replyHandler(data.base64EncodedString(), nil)

        case "mkdir":
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                replyHandler(nil, nil)
            } catch { replyHandler(nil, "mkdir: \(error.localizedDescription)") }

        case "readdir":
            // Return name + directory flag per entry so the JS shim can honor Node's
            // `{ withFileTypes: true }` (callers then expect Dirent objects with
            // `.isDirectory()`). One round-trip instead of a stat per entry.
            let entries = (try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            let listing: [[String: Any]] = entries.map { child in
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return ["name": child.lastPathComponent, "dir": isDir]
            }
            replyHandler(listing, nil)

        case "stat":
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if !exists { replyHandler(["exists": false], nil); return }
            let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? Int) ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            replyHandler(["exists": true, "dir": isDir.boolValue, "size": size,
                          "mtimeMs": mtime * 1000], nil)

        case "unlink":
            try? fm.removeItem(at: url)
            replyHandler(nil, nil)

        default:
            replyHandler(nil, "unknown op: \(op)")
        }
    }
}
