import Foundation
import AppKit

/// Plays the macOS system default alert when a navigation / route-loop
/// / random-walk run finishes naturally (i.e. arrives at its
/// destination as opposed to being explicitly stopped).
///
/// We deliberately use only stock NSSound named sounds (`Glass.aiff` by
/// default — the same one used by Mail / Calendar notifications). No
/// custom audio is bundled, so the .app stays small and there's never
/// any third-party-asset licensing question.
enum AlertSoundService {

    /// Named system sound shipped with every macOS install. Picked
    /// because it's pleasant, clearly recognisable as a "done" cue,
    /// and short enough not to annoy.
    private static let defaultSoundName: NSSound.Name = NSSound.Name("Glass")

    /// Play the system alert. Returns immediately; the actual playback
    /// is async. Multiple back-to-back calls (e.g. two routes finishing
    /// within milliseconds of each other) replace the previous play —
    /// NSSound handles this gracefully without queueing.
    @MainActor
    static func playRouteComplete() {
        if let sound = NSSound(named: defaultSoundName) {
            sound.play()
            return
        }
        // Fallback if the named sound is missing for any reason —
        // NSBeep is always available and matches the user's system
        // alert volume setting.
        NSSound.beep()
    }
}
