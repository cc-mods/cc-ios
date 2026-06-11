import AVFoundation

/// Configures the app's audio session for game playback and surfaces interruption
/// events (phone calls, Siri, other apps) so the host can pause/resume the game.
///
/// Category rationale: `.playback` is the correct category for a game and — crucially on
/// iOS — it lets the Web Audio `AudioContext` actually render. CrossCode plays background
/// music through HTML5 `<audio>` (which autoplays once
/// `mediaTypesRequiringUserActionForPlayback` is cleared) but plays all sound effects
/// through Web Audio; under the `.ambient` category iOS leaves the Web Audio context
/// effectively silent, so music was audible while SFX were not. `.playback` fixes that and
/// matches how games normally behave (audio plays even with the ring/silent switch on).
enum AudioSession {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            NSLog("[cc audio] failed to activate session: %@", error.localizedDescription)
        }
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
