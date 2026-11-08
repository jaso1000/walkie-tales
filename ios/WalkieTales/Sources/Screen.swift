import UIKit

/// Dimming, night light, the bedtime black screen and "screen off" from the remote.
extension PlayerViewController {

    /// Any touch: undim and restart the dim countdown. Returns false if the touch should be swallowed.
    func userTouched() -> Bool {
        if Finder.shared.ringing { Finder.shared.stop(); return false } // found it: a tap stops the ringing
        if screenLocked { return false }        // switched off from the remote: touches do nothing
        if dimmed { wake(); return false }      // first touch only wakes the screen
        wake()
        return true
    }

    func wake() {
        if screenLocked { return }
        if dimmed {
            UIScreen.main.brightness = savedBrightness
            night.isHidden = true
            blackout.isHidden = true
            dimmed = false
        }
        dimTimer?.invalidate()
        var secs = Store.int("dim_after")
        if Bedtime.darkOn { secs = secs == 0 ? 30 : min(secs, 30) } // bedtime: black again after 30 s
        if secs > 0 {
            dimTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(secs), repeats: false) { [weak self] _ in self?.dimNow() }
        }
    }

    @objc func dimNow() {
        if screenLocked { return }
        if !dimmed { savedBrightness = UIScreen.main.brightness }
        let dark = Bedtime.darkOn
        let nightLight = !dark && Store.bool("night_light")
        UIScreen.main.brightness = dark ? 0 : (nightLight ? 0.12 : 0.02)
        blackout.isHidden = !dark
        night.isHidden = !nightLight
        if dark { presentedViewController?.dismiss(animated: false) }
        dimmed = true
        updateKeepOn()
    }

    /// Bedtime starts or ends while the screen is already dimmed: switch between black and the normal dim.
    func checkBedtime() {
        if screenLocked || !dimmed { return }
        if Bedtime.darkOn == blackout.isHidden { dimNow() }
    }

    func setScreenLocked(_ on: Bool) {
        if on == screenLocked { return }
        if on {
            if !dimmed { savedBrightness = UIScreen.main.brightness }
            screenLocked = true
            dimTimer?.invalidate()
            presentedViewController?.dismiss(animated: false)
            blackout.isHidden = false
            night.isHidden = true
            UIScreen.main.brightness = 0
            dimmed = true
        } else {
            screenLocked = false
            wake()
        }
        updateKeepOn() // lets iOS Auto-Lock switch the display off for real
    }
}

/// Lets the player see every touch first (to undim, and to ignore touches while the screen is "off").
final class TouchWindow: UIWindow {
    weak var player: PlayerViewController?

    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches, let touches = event.allTouches, touches.contains(where: { $0.phase == .began }), let p = player {
            if !p.userTouched() { return }
        }
        super.sendEvent(event)
    }
}
