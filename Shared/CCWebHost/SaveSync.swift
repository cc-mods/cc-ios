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
    /// Implementations must be **non-destructive to an existing local save** (phone-authoritative):
    /// only seed when there is no local save; never silently overwrite on-device progress.
    func pullIfNewerBlocking(timeout: TimeInterval) -> Bool

    /// Push the given raw `cc.save` string to the remote. Implementations must be fail-safe
    /// (dedupe echoes, never block the game, no-op when unconfigured/unreachable).
    func push(_ value: String)

    /// **Confirmed** flush for a *deliberate* exit (the in-game "Close Game" / "Restart Game"
    /// buttons, which the host fully controls — see `ControlBridge`). Pushes the current local save
    /// and calls back on the main queue with whether the remote is confirmed to hold it
    /// (`true` = safe to proceed / nothing to do; `false` = could not confirm within `timeout`).
    ///
    /// Unlike `push` (fire-and-forget), this is the one place the host *waits* on the network before
    /// acting — but only because it owns the termination, so blocking briefly is legitimate. It MUST
    /// still be bounded: call back by `timeout` no matter what (a dead network must never trap the
    /// user in the app), and call back `true` immediately when there is nothing to sync
    /// (unconfigured, or already in sync). Default: `completion(true)` at once (nothing to block on).
    func flush(timeout: TimeInterval, completion: @escaping (Bool) -> Void)

    /// **Durable** background flush for app suspension/termination (`didEnterBackground`). Hands the
    /// upload to the OS so it completes even if the app is suspended or force-quit (e.g. a background
    /// `URLSession`). Returns immediately; durability is the implementation's job. Default: no-op.
    func flushInBackground()
}

public extension SaveSyncProvider {
    /// Default: nothing to confirm — let the caller proceed without waiting.
    func flush(timeout: TimeInterval, completion: @escaping (Bool) -> Void) { completion(true) }

    /// Default: no durable-background capability.
    func flushInBackground() {}
}

/// Optional **consent-based** pull, for hubs that resolve conflicts by content identity and want the
/// user to confirm before a remote save replaces the on-device one (the GitHub hub's "newer save
/// detected — load? Y/N"). Kept separate from `SaveSyncProvider` so the launch path stays silent and
/// non-destructive while this interactive path is opt-in. UIKit-free: the host owns the actual prompt.
public protocol ConsentPullProvider: AnyObject {
    /// Non-destructive check: if the hub holds a save that should be offered to the user (a local save
    /// exists and the hub's differs/advanced), call back with its raw bytes; otherwise `nil`. Must
    /// never write the local save itself.
    func checkForConsentPull(completion: @escaping (Data?) -> Void)

    /// Apply bytes the user accepted (write them to the local save file + record the sync point).
    /// Returns success.
    func applyPulledConsent(_ data: Data) -> Bool
}

/// Process-wide registry for the optional save-sync provider.
///
/// Stays `nil` in a standalone cc-ios build (→ no network sync). cc-tailsync's `integrate-ios.sh`
/// wires a provider in here at app launch (see `SaveSyncBootstrap`).
public enum SaveSync {
    public static var provider: SaveSyncProvider?

    /// Optional consent-based pull provider (e.g. the GitHub hub). `nil` → no interactive pull.
    public static var consentProvider: ConsentPullProvider?

    /// Set by the provider to receive background-`URLSession` completion events. iOS relaunches the
    /// app (often into the background) to deliver the results of a transfer that finished while it
    /// was suspended/terminated, calling the app delegate's
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. cc-ios's `AppDelegate`
    /// forwards that here so the provider (which owns the background session) can reconnect to its
    /// session and run the system completion handler when its events drain. `nil` → no durable
    /// background session is in play (standalone / Tailscale), so the app delegate simply completes.
    public static var backgroundEventsHandler: ((_ identifier: String, _ completion: @escaping () -> Void) -> Void)?
}
