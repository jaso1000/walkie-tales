import Network
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
            OffGuard.start(self)
        } else {
            screenLocked = false
            OffGuard.stop()
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

/// Only the remote can turn the screen back on, so without Wi-Fi it could stay off for good.
/// While it's off from the remote: after a minute without Wi-Fi, or as soon as someone wakes the iPhone while
/// there's no Wi-Fi, turn the screen back on and let the player work normally.
enum OffGuard {
    private static let monitor: NWPathMonitor = {
        let m = NWPathMonitor(requiredInterfaceType: .wifi)
        m.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                let up = path.status == .satisfied
                if up { downSince = nil } else if downSince == nil { downSince = Date() }
                wifiUp = up
            }
        }
        m.start(queue: DispatchQueue.global(qos: .utility))
        return m
    }()
    private static var wifiUp = true
    private static var downSince: Date?
    private static var timer: Timer?
    private static var woke: NSObjectProtocol?
    private static weak var player: PlayerViewController?

    static func start(_ p: PlayerViewController) {
        _ = monitor
        player = p
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in check(grace: 60) }
        if woke == nil {
            woke = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                check(grace: 0) // someone woke the iPhone: don't leave them with a black screen
            }
        }
    }

    static func stop() {
        timer?.invalidate(); timer = nil
        if let w = woke { NotificationCenter.default.removeObserver(w); woke = nil }
    }

    private static func check(grace: TimeInterval) {
        guard let p = player, p.screenLocked, !wifiUp, let since = downSince else { return }
        if Date().timeIntervalSince(since) >= grace {
            p.setScreenLocked(false)
            p.flash("No Wi-Fi, so the screen is back on", 6)
        }
    }
}
