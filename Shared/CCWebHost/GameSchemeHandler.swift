import Foundation
import WebKit

/// Serves the CrossCode asset tree (the `app.nw/assets` directory) to a `WKWebView`
/// over a custom URL scheme, exactly mirroring CrossAndroid's
/// `WebViewClient.shouldInterceptRequest`. This is the iOS analog and is the ONLY
/// thing the game needs to read its files — it loads everything via XHR / jQuery
/// `.ajax` against relative paths, so a custom-scheme responder fully satisfies it.
///
/// No synchronous JS↔native bridge is required: the README's "highest friction"
/// risk does not apply to this build (verified against game.compiled.js — zero
/// `readFileSync`/`writeFileSync`, saves go through `localStorage`).
public final class GameSchemeHandler: NSObject, WKURLSchemeHandler {

    /// Custom scheme the game is served from. Must be a non-special scheme so WKWebView
    /// routes it to us. The host component is cosmetic (`game`).
    public static let scheme = "ccgame"

    private let root: URL
    private let log: (String) -> Void
    private let preferM4AAudio: Bool
    private let forceBrowserPlatform: Bool
    private let overlayRoot: URL?

    /// - Parameters:
    ///   - root: Filesystem directory that maps to the web root (i.e. `app.nw/assets`).
    ///   - preferM4AAudio: When true, the served `game.compiled.js` is patched so the
    ///     engine's audio-format preference list puts **M4A first**. CrossCode ships
    ///     Ogg Vorbis audio, which iOS WebKit cannot decode via Web Audio (it crashes with
    ///     a "Web Audio Load Error"). With this on — and the media tree transcoded to
    ///     `.m4a` (AAC) — iOS picks the natively-decodable format instead. Leave off on
    ///     macOS, where Ogg decodes fine.
    ///   - forceBrowserPlatform: When true, the served `game.compiled.js` is patched so the
    ///     engine always selects its BROWSER platform path even if `window.require` is
    ///     defined. This lets us expose a `require("fs")` shim (for CCModManager one-click
    ///     installs) without the game mistaking itself for the NW.js desktop build.
    ///   - overlayRoot: Optional writable directory checked *before* `root` for each request.
    ///     Used to serve installed mods from `Documents/mods` on top of the read-only bundle.
    ///   - log: Optional sink for diagnostics (404s, ranges, patches). Defaults to no-op.
    public init(root: URL,
                preferM4AAudio: Bool = false,
                forceBrowserPlatform: Bool = false,
                overlayRoot: URL? = nil,
                log: @escaping (String) -> Void = { _ in }) {
        self.root = root.standardizedFileURL
        self.preferM4AAudio = preferM4AAudio
        self.forceBrowserPlatform = forceBrowserPlatform
        self.overlayRoot = overlayRoot?.standardizedFileURL
        self.log = log
        super.init()
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let request = urlSchemeTask.request
        guard let url = request.url else {
            urlSchemeTask.didFailWithError(Self.error("missing URL"))
            return
        }

        // The CrossCode extension/DLC loader hits `…/page/api/get-extension-list.php`.
        // There is no PHP on a static host; return an empty list so it cleanly loads
        // zero extensions instead of erroring. (A real list can be served later.)
        if url.path.hasSuffix("get-extension-list.php") {
            respondFull(urlSchemeTask, url: url, data: Data("[]".utf8), mime: "application/json")
            return
        }

        // Resolve the request path against the asset root, with a traversal guard.
        var relativePath = url.path
        if relativePath.hasPrefix("/") { relativePath.removeFirst() }
        relativePath = relativePath.removingPercentEncoding ?? relativePath

        // Synthesize mods.json = bundled list + any mods installed into the overlay, so
        // CCLoader loads newly CCModManager-installed mods on the next launch.
        if overlayRoot != nil, relativePath == "mods.json" || relativePath.hasSuffix("/mods.json") {
            let merged = synthesizedModsJSON(bundledRelativePath: relativePath)
            respondFull(urlSchemeTask, url: url, data: merged, mime: "application/json")
            return
        }

        // Resolve against the writable overlay first (installed mods in Documents/mods),
        // then fall back to the read-only bundle. Both are traversal-guarded.
        let fileURL: URL
        if let resolved = resolveReadable(relativePath) {
            fileURL = resolved
        } else {
            let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
            guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
                log("403 (escape) \(relativePath)")
                respondStatus(urlSchemeTask, url: url, status: 403)
                return
            }
            fileURL = candidate
        }

        // CCLoader (browser mode) probes for mod folders with `HEAD assets/mods/<name>` and
        // treats any non-404 as "exists". Resolve directories to a 200 so mod discovery works.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            let headers = [
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": "0",
                "Access-Control-Allow-Origin": "*"
            ]
            send(urlSchemeTask, url: url, status: 200, headers: headers, body: Data())
            return
        }

        guard var data = try? Data(contentsOf: fileURL) else {
            log("404 \(relativePath)")
            respondStatus(urlSchemeTask, url: url, status: 404)
            return
        }

        if forceBrowserPlatform, fileURL.lastPathComponent == "game.compiled.js" {
            data = Self.patchForceBrowserPlatform(in: data, log: log)
        }


        // iOS audio fix: rewrite the engine's format-preference list in the main game
        // bundle so M4A (AAC) is chosen ahead of Ogg Vorbis, which iOS WebKit can't decode.
        if preferM4AAudio, fileURL.lastPathComponent == "game.compiled.js" {
            data = Self.patchAudioFormatPreference(in: data, log: log)
        }

        let mime = Self.mimeType(forExtension: fileURL.pathExtension)

        // Honour HTTP Range for media (HTML5 <audio>/<video> seek with byte ranges).
        if let rangeHeader = request.value(forHTTPHeaderField: "Range"),
           let (start, end) = Self.parseRange(rangeHeader, total: data.count) {
            let slice = data.subdata(in: start ..< (end + 1))
            let headers = [
                "Content-Type": mime,
                "Content-Length": "\(slice.count)",
                "Content-Range": "bytes \(start)-\(end)/\(data.count)",
                "Accept-Ranges": "bytes",
                "Access-Control-Allow-Origin": "*"
            ]
            send(urlSchemeTask, url: url, status: 206, headers: headers, body: slice)
            return
        }

        respondFull(urlSchemeTask, url: url, data: data, mime: mime)
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // All responses are produced synchronously within `start`, so there is never an
        // in-flight task to cancel here.
    }

    // MARK: - Response helpers

    private func respondFull(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
        let headers = [
            "Content-Type": mime,
            "Content-Length": "\(data.count)",
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*"
        ]
        send(task, url: url, status: 200, headers: headers, body: data)
    }

    private func respondStatus(_ task: WKURLSchemeTask, url: URL, status: Int) {
        send(task, url: url, status: status,
             headers: ["Access-Control-Allow-Origin": "*"], body: Data())
    }

    private func send(_ task: WKURLSchemeTask, url: URL, status: Int,
                      headers: [String: String], body: Data) {
        guard let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(Self.error("failed to build response"))
            return
        }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    // MARK: - Static utilities

    private static func error(_ message: String) -> NSError {
        NSError(domain: "GameSchemeHandler", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Builds a `mods.json` that merges the bundled mod list with mods present in the
    /// writable overlay (`Documents/mods`). Overlay entries are added as either a folder
    /// name (unpacked mod) or a `<id>.ccmod` filename (packed), matching how CCLoader's
    /// browser mode resolves `assets/mods/<entry>`. De-duplicated, bundled order preserved.
    private func synthesizedModsJSON(bundledRelativePath: String) -> Data {
        var names: [String] = []
        var seen = Set<String>()
        func add(_ n: String) { if !n.isEmpty && !seen.contains(n) { seen.insert(n); names.append(n) } }

        // 1. Bundled mods.json (read-only).
        let bundled = root.appendingPathComponent(bundledRelativePath)
        if let data = try? Data(contentsOf: bundled),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            arr.forEach(add)
        }

        // 2. Overlay mods (installed at runtime) live at <overlayRoot>/assets/mods.
        if let overlayRoot = overlayRoot {
            let modsDir = overlayRoot.appendingPathComponent("assets/mods")
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: modsDir.path)) ?? []
            for entry in entries.sorted() {
                if entry.hasPrefix(".") { continue }
                let full = modsDir.appendingPathComponent(entry)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: full.path, isDirectory: &isDir)
                if isDir.boolValue || entry.hasSuffix(".ccmod") { add(entry) }
            }
        }

        let json = (try? JSONSerialization.data(withJSONObject: names)) ?? Data("[]".utf8)
        log("mods.json synthesized: \(names.count) mods")
        return json
    }

    /// Resolves a request path against the writable overlay (installed mods) first, then
    /// the read-only bundle. Returns the first existing file/dir, or nil if neither has it
    /// (caller then does the bundle-with-traversal-guard fallback). Both roots are guarded.
    private func resolveReadable(_ relativePath: String) -> URL? {
        guard let overlayRoot = overlayRoot else { return nil }
        let candidate = overlayRoot.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path == overlayRoot.path || candidate.path.hasPrefix(overlayRoot.path + "/") else {
            return nil
        }
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Forces CrossCode's platform detection to BROWSER even when `window.require` exists,
    /// so we can expose a `require("fs")` shim (CCModManager installs) without the engine
    /// switching to its NW.js desktop path. Replaces the `window.require && …` test with a
    /// literal that drops the require check.
    static func patchForceBrowserPlatform(in data: Data, log: (String) -> Void) -> Data {
        let original = "ig.platform=window.require&&\"object\"==typeof window.process?ig.PLATFORM_TYPES.DESKTOP:"
        let replacement = "ig.platform=false?ig.PLATFORM_TYPES.DESKTOP:"
        guard let text = String(data: data, encoding: .utf8), text.contains(original) else {
            log("force-browser: pattern not found")
            return data
        }
        log("force-browser: platform pinned to BROWSER")
        return Data(text.replacingOccurrences(of: original, with: replacement).utf8)
    }

    /// Rewrites CrossCode's audio handling so M4A (AAC) is always selected.
    ///
    /// The engine defines `ig.Sound.use=[ig.Sound.FORMAT.OGG,ig.Sound.FORMAT.MP3]` and
    /// picks the first format whose MIME passes `canPlayType`. iOS/WebKit cannot decode
    /// Ogg Vorbis (a fatal "Web Audio Load Error"), and it also reports the engine's exact
    /// M4A MIME string (`audio/mp4; codecs=mp4a`) as unplayable — so naive reordering
    /// still falls through to Ogg. We therefore make two minimal edits:
    ///   1. Put `M4A` at the head of the preference list, and
    ///   2. Force the selection predicate to accept M4A regardless of `canPlayType`.
    /// AAC-in-MP4 is natively decodable on all Apple platforms, so forcing it is safe; the
    /// engine strips each sound's extension and re-appends `format.ext`, yielding `.m4a`
    /// requests that the transcoded media tree satisfies.
    static func patchAudioFormatPreference(in data: Data, log: (String) -> Void) -> Data {
        guard var text = String(data: data, encoding: .utf8) else {
            log("audio-patch: skipped (not UTF-8)")
            return data
        }

        var applied: [String] = []

        let listOriginal = "ig.Sound.use=[ig.Sound.FORMAT.OGG,ig.Sound.FORMAT.MP3]"
        let listPatched = "ig.Sound.use=[ig.Sound.FORMAT.M4A,ig.Sound.FORMAT.OGG,ig.Sound.FORMAT.MP3]"
        if text.contains(listOriginal) {
            text = text.replacingOccurrences(of: listOriginal, with: listPatched)
            applied.append("reorder")
        }

        // Force the format-selection predicate to accept the M4A entry unconditionally.
        let predOriginal = "if(a.canPlayType(c.mime)){this.format=c;break}"
        let predPatched = "if(c.ext==\"m4a\"||a.canPlayType(c.mime)){this.format=c;break}"
        if text.contains(predOriginal) {
            text = text.replacingOccurrences(of: predOriginal, with: predPatched)
            applied.append("force-select")
        }

        if applied.isEmpty {
            log("audio-patch: no patterns matched (already patched or version mismatch)")
            return data
        }
        log("audio-patch: M4A audio (\(applied.joined(separator: "+")))")
        return Data(text.utf8)
    }

    /// Parses a single-range `Range: bytes=START-END` header. Supports open-ended
    /// (`START-`) and suffix (`-N`) forms. Returns an inclusive `(start, end)` pair.
    static func parseRange(_ header: String, total: Int) -> (Int, Int)? {
        guard total > 0 else { return nil }
        guard header.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let firstStr = parts[0].trimmingCharacters(in: .whitespaces)
        let secondStr = parts[1].trimmingCharacters(in: .whitespaces)

        var start: Int
        var end: Int
        if firstStr.isEmpty {
            // Suffix range: last N bytes.
            guard let n = Int(secondStr), n > 0 else { return nil }
            start = max(0, total - n)
            end = total - 1
        } else {
            guard let s = Int(firstStr) else { return nil }
            start = s
            if secondStr.isEmpty {
                end = total - 1
            } else {
                guard let e = Int(secondStr) else { return nil }
                end = e
            }
        }
        end = min(end, total - 1)
        guard start >= 0, start <= end else { return nil }
        return (start, end)
    }

    /// Minimal extension→MIME map covering everything CrossCode serves.
    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "text/javascript; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "svg":         return "image/svg+xml"
        case "ico":         return "image/x-icon"
        case "ogg", "oga":  return "audio/ogg"
        case "mp3":         return "audio/mpeg"
        case "m4a", "aac":  return "audio/mp4"
        case "wav":         return "audio/wav"
        case "mp4", "m4v":  return "video/mp4"
        case "ttf":         return "font/ttf"
        case "otf":         return "font/otf"
        case "woff":        return "font/woff"
        case "woff2":       return "font/woff2"
        case "txt":         return "text/plain; charset=utf-8"
        case "xml":         return "application/xml"
        default:            return "application/octet-stream"
        }
    }
}
