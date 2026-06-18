import SwiftUI

/// cc-ios app entry point. Hosts CrossCode full-screen in a `WKWebView` driven by the
/// shared `CCWebHost` layer (the same code proven in the macOS harness).
@main
struct CCIOSApp: App {
    // Bridges UIKit's app-delegate callbacks into the SwiftUI lifecycle — needed for the
    // background-URLSession hand-back (`handleEventsForBackgroundURLSession`) that completes a durable
    // save upload after the app was suspended/terminated.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Wire in optional wireless save sync if present (no-op unless cc-tailsync is integrated).
        SaveSyncBootstrap.installIfAvailable()
    }

    var body: some Scene {
        WindowGroup {
            GameView()
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}
