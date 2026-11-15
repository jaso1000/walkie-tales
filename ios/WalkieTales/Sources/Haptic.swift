import UIKit

/// Small taps of vibration for the player's buttons, matching the Android player: a light tick for small things
/// (volume, skip, the sleep timer, headphones, Library, Tracks, swipes), a firmer click for choosing something
/// (play/pause, a tile, a song) and a heavy one for press-and-hold. iOS follows Settings → Sounds & Haptics →
/// System Haptics by itself, so there's no setting of our own.
enum Haptic {
    case tick, click, heavy

    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let strong = UIImpactFeedbackGenerator(style: .heavy)

    static func play(_ kind: Haptic) {
        let g = kind == .tick ? light : kind == .click ? medium : strong
        g.impactOccurred()
        g.prepare() // keeps the Taptic Engine ready so the next tap isn't late
    }
}
