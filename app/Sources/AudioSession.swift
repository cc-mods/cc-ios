import AVFoundation

/// Configures the app's audio session for game playback and surfaces interruption
/// events (phone calls, Siri, other apps) so the host can pause/resume the game.
///
/// Category rationale: `.ambient` respects the hardware mute switch (expected on iOS),
/// mixes politely with other audio, and never plays in the background — the game is
/// paused while backgrounded anyway. CrossCode drives its own Web Audio graph; we only
/// own the session policy and interruption signalling.
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
