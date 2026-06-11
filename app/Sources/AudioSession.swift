import AVFoundation

/// Configures the app's audio session for game playback and surfaces interruption
/// events (phone calls, Siri, other apps) so the host can pause/resume the game.
///
/// Category rationale: `.ambient`. The silent-SFX problem was **not** the category — it was
/// CrossCode's Web Audio `AudioContext` starting suspended on iOS with nothing to resume it
/// (background music uses HTML5 `<audio>`, which autoplays, so only SFX were affected). The
/// real fix is `Bootstrap.webAudioUnlockJavaScript`, which resumes the context on the first
/// user gesture; Web Audio renders fine under `.ambient`. We deliberately avoid `.playback`
/// here: activating a `.playback` session at launch blocked WebKit's audio init on device and
/// left the game on a black screen. `.ambient` also respects the hardware mute switch, which
/// is the expected iOS behaviour.
enum AudioSession {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            NSLog("[cc audio] failed to activate session: %@", error.localizedDescription)
        }
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
