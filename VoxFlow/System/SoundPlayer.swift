import AppKit

/// The two moments Settings › General "Play sounds…" (ST-01) covers: a dictation starting
/// (`.listening` entered) and one finishing (`.inserted`/`.copied`).
enum DictationSound: Sendable { case start, end }

/// Plays `DictationSound`s, behind a protocol so `SoundCoordinator`'s tests can fake it without
/// touching real system sounds. `@MainActor`: `NSSound.play()` is an AppKit call, and
/// `SoundCoordinator` (the only caller) is main-actor-isolated anyway.
@MainActor
protocol SoundPlaying {
    func play(_ sound: DictationSound)
}

/// Production `SoundPlaying`: the system's own "Tink"/"Pop" named sounds (design ST-01, ruling 4).
struct NSSoundPlayer: SoundPlaying {
    func play(_ sound: DictationSound) {
        switch sound {
        case .start: NSSound(named: "Tink")?.play()
        case .end: NSSound(named: "Pop")?.play()
        }
    }
}
