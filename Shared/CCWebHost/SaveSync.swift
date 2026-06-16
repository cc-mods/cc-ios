import Foundation

/// Optional network save-sync seam.
///
/// This lives in the **shared host** (compiled into both the iOS app and the macOS harness), so it
/// is type-checked by `swift build` even though the concrete sync client ships separately.
///
/// cc-ios persists saves to a file on its own (`SaveBridge` + `SaveFolder`) and works **fully
/// standalone with no network**. *Wireless* sync — e.g. Tailscale, provided by the separate
/// **[cc-tailsync](https://github.com/cc-mods/cc-tailsync)** Swift package — is an OPTIONAL add-on:
/// it registers a provider in `SaveSync.provider`. When nothing is registered, every call here is a
/// silent no-op, so the app and harness build and run without cc-tailsync present.
public protocol SaveSyncProvider: AnyObject {
    /// Whether a sync endpoint is configured (e.g. `Documents/cc-sync.json` exists).
    var isConfigured: Bool { get }

    /// Blocking pull of a newer remote save into the local save file; returns whether it changed.
    /// Used at launch, before the save is injected, with a short timeout so boot stays snappy.
    func pullIfNewerBlocking(timeout: TimeInterval) -> Bool

    /// Push the given raw `cc.save` string to the remote. Implementations must be fail-safe
    /// (dedupe echoes, never block the game, no-op when unconfigured/unreachable).
    func push(_ value: String)
}

/// Process-wide registry for the optional save-sync provider.
///
/// Stays `nil` in a standalone cc-ios build (→ no network sync). cc-tailsync's `integrate-ios.sh`
/// wires a `TailscaleSyncClient` in here at app launch (see `SaveSyncBootstrap`).
public enum SaveSync {
    public static var provider: SaveSyncProvider?
}
