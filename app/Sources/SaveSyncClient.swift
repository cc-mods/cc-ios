import Foundation
import CommonCrypto

/// Optional wireless save sync against a `tools/save-server.py` instance (e.g. a PC on your
/// Tailscale network). Entirely **fail-safe**: if there's no config file, or the server is
/// unreachable, every call is a silent no-op — it can never block boot or break the game.
///
/// Config lives at `Documents/cc-sync.json` so it can be set without rebuilding (push it
/// with `xcrun devicectl device copy to … --source cc-sync.json --destination Documents/...`):
///
///     { "url": "http://100.x.y.z:8765", "token": "optional-bearer" }
///
/// The server mirrors the desktop `cc.save`, which Steam Cloud distributes across PCs — so
/// this bridges iOS into the same save, wirelessly.
final class SaveSyncClient {

    struct Config {
        let url: URL
        let token: String?
    }

    private let session: URLSession
    private var lastSyncedSha: String?

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: cfg)
    }

    /// Reads `Documents/cc-sync.json`, or `nil` if absent/invalid (→ sync disabled).
    static func loadConfig() -> Config? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cc-sync.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = obj["url"] as? String,
              let endpoint = URL(string: urlString) else {
            return nil
        }
        return Config(url: endpoint, token: obj["token"] as? String)
    }

    var isConfigured: Bool { Self.loadConfig() != nil }

    /// Blocking variant for use at launch (before the save is injected): pulls a newer
    /// remote save into `Documents/cc.save`, waiting up to `timeout` seconds. Returns
    /// whether the local file was updated. If sync isn't configured it returns instantly;
    /// if the server is slow/unreachable it gives up after the timeout and the game starts
    /// with the local save (the pull may still finish in the background for next launch).
    func pullIfNewerBlocking(timeout: TimeInterval) -> Bool {
        guard isConfigured else { return false }
        let sem = DispatchSemaphore(value: 0)
        var changed = false
        pullIfNewer { c in changed = c; sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
        return changed
    }

    private func authorized(_ request: inout URLRequest, _ config: Config) {
        if let token = config.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Two-way sync with the server, resolving by modification time with a content-hash
    /// short-circuit. Calls back `true` only if the local `Documents/cc.save` was updated
    /// from the server (caller should then load it).
    ///
    /// Resolution: identical hashes → nothing to do; otherwise the side with the newer
    /// mtime wins — a newer **remote** is pulled, a newer **local** is pushed. This avoids
    /// clobbering progress made offline on either side.
    func pullIfNewer(completion: @escaping (Bool) -> Void) {
        guard let config = Self.loadConfig() else { completion(false); return }
        var request = URLRequest(url: config.url.appendingPathComponent("status"))
        authorized(&request, config)

        session.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self else { completion(false); return }
            let local = Self.localSaveInfo()

            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(false); return
            }
            let remoteExists = (obj["exists"] as? Bool) == true
            let remoteSha = obj["sha256"] as? String ?? ""
            let remoteMtime = (obj["mtime"] as? Int) ?? 0

            // Nothing on the server → upload whatever we have locally.
            if !remoteExists {
                if let value = local?.value { self.push(value) }
                completion(false); return
            }
            // Nothing locally → take the server's save.
            guard let local = local else {
                self.downloadSave(config: config, expectedSha: remoteSha, completion: completion)
                return
            }
            // In sync already.
            if local.sha == remoteSha { self.lastSyncedSha = remoteSha; completion(false); return }
            // Newer side wins.
            if remoteMtime > local.mtime {
                self.downloadSave(config: config, expectedSha: remoteSha, completion: completion)
            } else {
                self.push(local.value)
                completion(false)
            }
        }.resume()
    }

    private func downloadSave(config: Config, expectedSha: String,
                             completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: config.url.appendingPathComponent("cc.save"))
        authorized(&request, config)
        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self = self,
                  let data = data, !data.isEmpty,
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                completion(false); return
            }
            do {
                try data.write(to: SaveBridge.saveFileURL, options: .atomic)
                self.lastSyncedSha = expectedSha
                NSLog("[cc sync] pulled %d bytes from server", data.count)
                completion(true)
            } catch {
                NSLog("[cc sync] pull write failed: %@", error.localizedDescription)
                completion(false)
            }
        }.resume()
    }

    /// Uploads the given save bytes to the server, skipping if unchanged since last sync.
    func push(_ value: String) {
        guard let config = Self.loadConfig() else { return }
        let data = Data(value.utf8)
        let sha = Self.sha256(data)
        guard sha != lastSyncedSha else { return }   // dedupe echoes

        var request = URLRequest(url: config.url.appendingPathComponent("cc.save"))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        authorized(&request, config)
        request.httpBody = data

        session.dataTask(with: request) { [weak self] _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                self?.lastSyncedSha = sha
                NSLog("[cc sync] pushed %d bytes to server", data.count)
            }
        }.resume()
    }

    // MARK: - Local save info

    private struct LocalInfo { let value: String; let sha: String; let mtime: Int }

    private static func localSaveInfo() -> LocalInfo? {
        let url = SaveBridge.saveFileURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let value = String(data: data, encoding: .utf8) else { return nil }
        let mtime: Int
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let date = attrs[.modificationDate] as? Date {
            mtime = Int(date.timeIntervalSince1970)
        } else {
            mtime = 0
        }
        return LocalInfo(value: value, sha: sha256(data), mtime: mtime)
    }

    private static func sha256(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
