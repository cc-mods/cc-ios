import UIKit

/// Minimal app delegate, wired into the SwiftUI lifecycle via `@UIApplicationDelegateAdaptor`
/// (see `CCIOSApp`). Its sole job is the one lifecycle callback SwiftUI's `App` cannot express: the
/// hand-back point for a **background `URLSession`**.
///
/// When a durable save upload (the cc-tailsync GitHub hub's `flushInBackground`) finishes while the
/// app is suspended or terminated, iOS relaunches the app — often straight into the background — and
/// calls this method so we can finish processing the transfer and then signal the system. We forward
/// it to whoever owns the background session (`SaveSync.backgroundEventsHandler`, set by the sync
/// provider at launch). With no provider wired (standalone build), there is no background session, so
/// we simply call the completion handler immediately.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if let handler = SaveSync.backgroundEventsHandler {
            handler(identifier, completionHandler)
        } else {
            completionHandler()
        }
    }
}
