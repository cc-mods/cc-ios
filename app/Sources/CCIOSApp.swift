import SwiftUI

/// cc-ios app entry point. Hosts CrossCode full-screen in a `WKWebView` driven by the
/// shared `CCWebHost` layer (the same code proven in the macOS harness).
@main
struct CCIOSApp: App {
    var body: some Scene {
        WindowGroup {
            GameView()
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}
