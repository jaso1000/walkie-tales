import AVFoundation
import AVKit
import AudioToolbox
import UIKit

/// A battery shape that fills up with the charge, with the percentage inside and a bolt while charging
/// (same drawing as the Android player's BatteryView). Red at 15% or less, green while charging.
final class BatteryView: UIView {
    /// Set only by the automated simulator test ("64", or "80c" for charging), which has no real battery.
    static var testOverride: String?
    private var pct = -1
    private var charging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ percent: Int, charging c: Bool) {
        if percent == pct && c == charging { return }
        pct = percent
        charging = c
        accessibilityLabel = percent < 0 ? nil : "Battery \(percent)%" + (c ? ", charging" : "")
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard pct >= 0 else { return }
        let w = bounds.width, h = bounds.height
        let tipW: CGFloat = 2.5, line: CGFloat = 1.5, radius: CGFloat = 5
        let bodyRight = w - tipW - 1

        // the charge inside
        let fill = charging ? UIColor(red: 0.30, green: 0.79, blue: 0.42, alpha: 0.55)
            : pct <= 15 ? UIColor(red: 1, green: 0.35, blue: 0.35, alpha: 0.7) : UIColor(white: 1, alpha: 0.28)
        let inset = line + 1
        let full = bodyRight - inset * 2
        let level = full * CGFloat(max(pct, 4)) / 100
        fill.setFill()
        UIBezierPath(roundedRect: CGRect(x: inset, y: inset, width: level, height: h - inset * 2), cornerRadius: radius - inset).fill()

        // the outline and its tip
        let outline = UIColor(white: 1, alpha: 0.7)
        outline.setStroke()
        let body = UIBezierPath(roundedRect: CGRect(x: line / 2, y: line / 2, width: bodyRight - line, height: h - line), cornerRadius: radius)
        body.lineWidth = line
        body.stroke()
        outline.setFill()
        UIBezierPath(roundedRect: CGRect(x: bodyRight + 0.5, y: h * 0.32, width: w - bodyRight - 0.5, height: h * 0.36), cornerRadius: 1).fill()

        // the number, with a bolt beside it while charging
        let text = "\(pct)%" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: UIColor.white]
        let ts = text.size(withAttributes: attrs)
        let boltW: CGFloat = charging ? 8 : 0
        let cx = bodyRight / 2 + boltW / 2
        text.draw(at: CGPoint(x: cx - ts.width / 2, y: (h - ts.height) / 2), withAttributes: attrs)
        if charging {
            let x = cx - ts.width / 2 - boltW - 1, top = h * 0.24, bot = h * 0.76, mid = h / 2
            let b = UIBezierPath()
            b.move(to: CGPoint(x: x + boltW * 0.65, y: top))
            b.addLine(to: CGPoint(x: x, y: mid + 0.6))
            b.addLine(to: CGPoint(x: x + boltW * 0.42, y: mid + 0.6))
            b.addLine(to: CGPoint(x: x + boltW * 0.3, y: bot))
            b.addLine(to: CGPoint(x: x + boltW, y: mid - 0.6))
            b.addLine(to: CGPoint(x: x + boltW * 0.55, y: mid - 0.6))
            b.close()
            UIColor.white.setFill()
            b.fill()
        }
    }
}

/// The headphones button. iPhones don't let apps switch Bluetooth on and off, so instead this opens Apple's
/// audio-output picker (the AirPlay sheet): tap it to send the sound to paired headphones or back to the speaker.
/// Green while headphones (Bluetooth, wired or AirPlay) are playing the sound.
final class HeadphonesButton: UIView {
    static let size: CGFloat = 38
    private let picker = AVRoutePickerView()
    private let icon = UIImageView()
    private var lastName: String?
    var onConnected: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 1, alpha: 0.15)
        layer.cornerRadius = Self.size / 2
        isAccessibilityElement = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.size).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size).isActive = true

        // The picker does the work; its own AirPlay glyph is hidden under our headphones icon.
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        picker.prioritizesVideoDevices = false
        picker.accessibilityLabel = "Headphones"
        picker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picker)
        icon.image = UIImage(systemName: "headphones", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.isUserInteractionEnabled = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        for v in [picker, icon] as [UIView] {
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                                         v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor)])
        }
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged), name: AVAudioSession.routeChangeNotification, object: nil)
        lastName = Self.output()
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Name of the headphones the sound is going to, or nil for the iPhone's own speaker.
    static func output() -> String? {
        let kinds: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .headphones, .usbAudio, .airPlay]
        guard let o = AVAudioSession.sharedInstance().currentRoute.outputs.first(where: { kinds.contains($0.portType) }) else { return nil }
        let n = o.portName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty || o.portType == .headphones ? "Headphones" : n
    }

    static var bluetooth: Bool {
        let bt: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { bt.contains($0.portType) }
    }

    @objc private func routeChanged() { DispatchQueue.main.async { self.update() } }

    func update() {
        let name = Self.output()
        backgroundColor = name != nil ? UIColor(red: 0.25, green: 0.68, blue: 0.37, alpha: 0.8) : UIColor(white: 1, alpha: 0.15)
        picker.accessibilityValue = name ?? "Speaker"
        if let n = name, n != lastName { onConnected?(n) }
        lastName = name
    }
}

/// "Ring the player" from the remote: a loud two-note alarm with vibration and the screen on for 30 seconds,
/// until someone taps the screen or the remote presses Stop (same as Android).
final class Finder {
    static let shared = Finder()
    static let seconds: TimeInterval = 30

    private var player: AVAudioPlayer?
    private var buzz: Timer?
    private var timeout: Timer?
    private var oldVolume: Float = 0
    private var wasLocked = false
    weak var owner: PlayerViewController?

    var ringing: Bool { player != nil }

    func start(_ vc: PlayerViewController) {
        owner = vc
        if ringing { // already ringing: start the 30 seconds again
            timeout?.invalidate()
            timeout = Timer.scheduledTimer(withTimeInterval: Self.seconds, repeats: false) { [weak self] _ in self?.stop() }
            return
        }
        Player.shared.pause()
        wasLocked = vc.screenLocked
        if vc.screenLocked { vc.setScreenLocked(false) }
        vc.wake()
        oldVolume = AVAudioSession.sharedInstance().outputVolume
        Volume.shared.overrideCap = true
        Volume.shared.slider?.setValue(1, animated: false)
        Volume.shared.slider?.sendActions(for: .valueChanged)
        guard let p = try? AVAudioPlayer(data: Self.tone()) else { restore(); return }
        p.numberOfLoops = -1
        p.volume = 1
        p.play()
        player = p
        UIApplication.shared.isIdleTimerDisabled = true
        buzz = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        vc.flash("Here I am! Tap the screen to stop", Self.seconds)
        timeout = Timer.scheduledTimer(withTimeInterval: Self.seconds, repeats: false) { [weak self] _ in self?.stop() }
    }

    func stop() {
        guard ringing else { return }
        player?.stop()
        player = nil
        restore()
        owner?.flash("", 0)
        if wasLocked { owner?.setScreenLocked(true) }
        owner?.updateKeepOn()
    }

    private func restore() {
        buzz?.invalidate(); buzz = nil
        timeout?.invalidate(); timeout = nil
        Volume.shared.slider?.setValue(oldVolume, animated: false)
        Volume.shared.slider?.sendActions(for: .valueChanged)
        Volume.shared.overrideCap = false
        Volume.shared.enforceCap()
    }

    /// Two short notes (A6, D7) and a pause, as 16-bit mono WAV: the same pattern as Android.
    static func tone(rate: Int = 44100) -> Data {
        let note = rate / 5, gap = rate * 2 / 5, fade = rate / 200
        var samples = [Int16](repeating: 0, count: note * 2 + gap)
        for i in 0..<(note * 2) {
            let inNote = i % note
            let hz = i < note ? 1760.0 : 2349.0
            let edge = min(1, Double(min(inNote, note - 1 - inNote)) / Double(fade))
            samples[i] = Int16(sin(2 * Double.pi * hz * Double(i) / Double(rate)) * 32000 * edge)
        }
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(samples.count * 2)
        d.append(Data("RIFF".utf8)); u32(36 + bytes); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}
