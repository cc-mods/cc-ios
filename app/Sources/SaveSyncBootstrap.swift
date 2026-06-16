import Foundation

/// Installs the optional network save-sync provider, if one is available.
///
/// **This is the STANDALONE (no-op) version.** cc-ios persists saves to a file on its own
/// (`SaveBridge` + `SaveFolder`) and needs no network, so nothing is registered and
/// `SaveSync.provider` stays `nil` — every sync call in `GameView` becomes a silent no-op.
///
/// Enabling wireless (Tailscale) sync is a single opt-in step:
/// **[cc-tailsync](https://github.com/cc-mods/cc-tailsync)**'s `tools/integrate-ios.sh` adds the
/// `CCTailsync` Swift package to the Xcode project and **replaces this file** with a version that
/// imports `CCTailsync`, conforms its `TailscaleSyncClient` to `SaveSyncProvider`, and registers it
/// in `SaveSync.provider`. Re-run that script to (re)enable sync; restoring this file disables it.
///
/// Keeping the wiring behind one well-known function (called from `CCIOSApp.init`) is what lets
/// cc-ios build with zero reference to cc-tailsync symbols when the package isn't linked.
enum SaveSyncBootstrap {
    static func installIfAvailable() {
        // No-op: file-based save persistence only.
        // Add wireless sync with cc-tailsync: https://github.com/cc-mods/cc-tailsync
    }
}
