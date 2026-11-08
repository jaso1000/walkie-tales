import AVFoundation
import MediaPlayer
import UIKit

/// Playback: folders of files or live streams, resume, shuffle/repeat, sleep timer, volume limit, lock-screen controls.
final class Player: NSObject {
    static let shared = Player()

    private(set) var folder: String?
    private(set) var tracks: [Track] = []
    private(set) var index = 0
    private(set) var player: AVPlayer?
    private(set) var connecting = false
    private var wantPlay = false
    private var endObserver: Any?
    private var statusObs: NSKeyValueObservation?
    private var timeObs: Any?
    private var fadeTimer: Timer?

    var sleepAt: Date?
    /// Called on the main thread whenever anything the screen shows changes.
    var onChange: (() -> Void)?
    var onMessage: ((String, TimeInterval) -> Void)?
    /// Called when the timer runs out (the screen can dim).
    var onSleep: (() -> Void)?

    private override init() {
        super.init()
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setActive(true)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        setupRemoteCommands()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    var current: Track? { tracks.indices.contains(index) ? tracks[index] : nil }
    var isLive: Bool { current?.live ?? false }
    var isPlaying: Bool { (player?.timeControlStatus == .playing || player?.rate ?? 0 > 0) && !connecting }
    var position: Double { player.map { CMTimeGetSeconds($0.currentTime()) }.flatMap { $0.isFinite ? $0 : nil } ?? 0 }
    var duration: Double {
        guard let d = player?.currentItem?.duration else { return 0 }
        let s = CMTimeGetSeconds(d)
        return s.isFinite ? s : 0
    }

    // MARK: opening folders

    func open(_ f: String, play: Bool) {
        let all = f == Store.ALL
        var list: [Track]
        if all {
            list = Store.folders().flatMap { Store.listTracks($0) }.filter { !$0.live } // no radio in "Everything"
        } else {
            list = Store.listTracks(f)
        }
        if list.isEmpty { onMessage?(all ? "There's no music on the phone yet" : "No music in “\(f)” yet", 4); return }
        let shuffle = all || Store.flag("shuffle", f, false)
        let resume = !shuffle && Store.flag("resume", f, true)
        if shuffle { list.shuffle() }
        savePosition()
        folder = f
        tracks = list
        var i = 0, ms = 0
        if resume { (i, ms) = Store.position(f); if !list.indices.contains(i) { i = 0; ms = 0 } }
        Store.set("last", f)
        if !play && list[i].live { release(); index = i; changed(); return } // don't connect to radio until asked
        start(i, at: Double(ms) / 1000, play: play)
    }

    func start(_ i: Int, at seconds: Double = 0, play: Bool) {
        guard tracks.indices.contains(i) else { return }
        release()
        index = i
        let t = tracks[i]
        let item: AVPlayerItem
        if t.live {
            connecting = true
            wantPlay = play
            onMessage?("Connecting to “\(t.name)”…", 20)
            item = AVPlayerItem(url: resolve(t.source))
        } else {
            item = AVPlayerItem(url: t.source)
        }
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = t.live
        player = p
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async { self?.itemStatus(it, track: t) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.trackEnded()
        }
        timeObs = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            self?.onChange?()
        }
        if !t.live && seconds > 0 { p.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
        if play && !t.live { self.play() } else { changed() }
    }

    private func itemStatus(_ it: AVPlayerItem, track: Track) {
        guard it === player?.currentItem else { return }
        if it.status == .failed {
            if track.live {
                connecting = false
                release()
                onMessage?("Can't reach “\(track.name)” right now", 8)
                changed()
            } else if tracks.count > 1 {
                start((index + 1) % tracks.count, play: true) // skip unplayable files
            } else {
                onMessage?("Couldn't play this", 5)
            }
        } else if it.status == .readyToPlay && connecting {
            connecting = false
            onMessage?("", 0)
            if wantPlay { play() } else { changed() }
            wantPlay = false
        }
    }

    /// .pls/.m3u "listen live" links: fetch and use the first stream inside.
    private func resolve(_ u: URL) -> URL {
        let ext = u.pathExtension.lowercased()
        guard ext == "pls" || ext == "m3u", let d = try? Data(contentsOf: u), let s = String(data: d, encoding: .utf8) else { return u }
        for l in s.components(separatedBy: .newlines) {
            let line = l.trimmingCharacters(in: .whitespaces)
            let v = line.lowercased().hasPrefix("file") ? String(line.split(separator: "=", maxSplits: 1).last ?? "") : line
            if Store.isUrl(v), let r = URL(string: v) { return r }
        }
        return u
    }

    private func release() {
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        if let o = timeObs { player?.removeTimeObserver(o) }
        endObserver = nil; timeObs = nil; statusObs = nil
        player?.pause()
        player = nil
        connecting = false
        fadeTimer?.invalidate()
    }

    // MARK: controls

    func play() {
        guard let p = player else { return }
        if connecting { wantPlay = true; changed(); return }
        try? AVAudioSession.sharedInstance().setActive(true)
        Volume.shared.enforceCap()
        fadeTimer?.invalidate()
        if Store.bool("fade_in") {
            p.volume = 0
            p.play()
            var v: Float = 0
            fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
                v += 0.05
                self?.player?.volume = min(1, v)
                if v >= 1 { t.invalidate() }
            }
        } else {
            p.volume = 1
            p.play()
        }
        changed()
    }

    func pause() {
        wantPlay = false
        fadeTimer?.invalidate()
        player?.pause()
        savePosition()
        changed()
    }

    func toggle() {
        if connecting { if wantPlay { pause() } else { play() }; return }
        if player == nil {
            if isLive { start(index, play: true) } else if let f = folder { open(f, play: true) }
            return
        }
        if isPlaying { pause() } else { play() }
    }

    func next() {
        if isLive {
            if tracks.count > 1 { start((index + 1) % tracks.count, play: true) } else { onMessage?("That's the only station here", 2.5) }
            return
        }
        guard player != nil else { onMessage?("Nothing is playing", 1.5); return }
        if index + 1 < tracks.count { start(index + 1, play: true) }
        else if repeats { start(0, play: true) }
        else { onMessage?("That's the last one", 2.5) }
    }

    func prev() {
        if isLive {
            start(index > 0 ? index - 1 : tracks.count - 1, play: true)
            return
        }
        guard let p = player else { return }
        if position > 3 || index == 0 { p.seek(to: .zero); changed() } else { start(index - 1, play: isPlaying) }
    }

    func restart() {
        guard folder != nil else { return }
        start(0, play: true)
        onMessage?("Back to the beginning", 2.5)
    }

    func seek(_ seconds: Double) {
        guard let p = player, !isLive else { return }
        p.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        savePosition(at: seconds)
        changed()
    }

    func stop() {
        savePosition()
        release()
        folder = nil
        tracks = []
        index = 0
        changed()
    }

    var repeats: Bool { folder == Store.ALL || (folder.map { Store.flag("repeat", $0, false) } ?? false) }

    private func trackEnded() {
        if index + 1 < tracks.count {
            start(index + 1, play: true)
        } else if repeats {
            if folder == Store.ALL || (folder.map { Store.flag("shuffle", $0, false) } ?? false) { tracks.shuffle() }
            start(0, play: true)
        } else {
            if let f = folder { Store.savePosition(f, index: 0, ms: 0) }
            start(0, play: false)
            onMessage?("The end ★", 5)
        }
    }

    func savePosition(at seconds: Double? = nil) {
        guard let f = folder, f != Store.ALL, player != nil, !Store.flag("shuffle", f, false) else { return }
        let s = isLive ? 0 : (seconds ?? position)
        Store.savePosition(f, index: index, ms: Int(s * 1000))
    }

    private func changed() {
        updateNowPlaying()
        onChange?()
    }

    // MARK: sleep timer

    func setSleep(minutes: Int) {
        let m = max(0, min(240, minutes))
        sleepAt = m == 0 ? nil : Date().addingTimeInterval(Double(m) * 60)
        if m == 0 { player?.volume = 1 }
        onMessage?(m == 0 ? "Sleep timer off" : "Music stops in \(m) minutes", 2.5)
        onChange?()
    }

    private var ticks = 0
    private func tick() {
        if let at = sleepAt {
            let left = at.timeIntervalSinceNow
            if left <= 0 {
                sleepAt = nil
                pause()
                player?.volume = 1
                onMessage?("Goodnight", 6)
                onSleep?()
            } else if left < 15, isPlaying, fadeTimer?.isValid != true {
                player?.volume = Float(left / 15) // fade out over the last 15 seconds
            }
        }
        ticks += 1
        if ticks % 10 == 0, isPlaying { savePosition() }
        Volume.shared.enforceCap()
    }

    // MARK: lock screen, headphones, Bluetooth

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            if self?.isPlaying != true { self?.toggle() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.prev(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { self?.seek(e.positionTime) }
            return .success
        }
    }

    var nowArt: UIImage?

    func updateNowPlaying() {
        guard let t = current, let f = folder else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.name,
            MPMediaItemPropertyAlbumTitle: Store.label(f),
            MPMediaItemPropertyArtist: "WalkieTales",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: t.live,
        ]
        if !t.live, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let a = nowArt { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: a.size) { _ in a } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    @objc private func routeChanged(_ n: Notification) {
        guard let r = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: r) == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { // headphones unplugged / speaker disconnected: don't blast the phone speaker
            if self.isPlaying { self.pause(); self.onMessage?("Paused — speaker disconnected", 4) }
        }
    }

    @objc private func interrupted(_ n: Notification) {
        guard let r = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: r) == .began else { return }
        DispatchQueue.main.async { self.pause() }
    }
}

/// System volume with a grown-up limit (and a lower one at bedtime). iOS has no public API to set the
/// system volume, so this uses the hidden slider inside MPVolumeView, which is the long-standing way apps do it.
final class Volume: NSObject {
    static let shared = Volume()
    let steps = 16
    let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
    private var obs: NSKeyValueObservation?

    private override init() {
        super.init()
        obs = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.enforceCap(); Player.shared.onChange?() }
        }
    }

    var slider: UISlider? { view.subviews.compactMap { $0 as? UISlider }.first }

    var level: Int { Int((AVAudioSession.sharedInstance().outputVolume * Float(steps)).rounded()) }

    var capPercent: Int {
        var pct = Store.int("max_volume")
        if quietNow { pct = min(pct, Store.int("quiet_volume")) }
        return pct
    }

    var capSteps: Int { max(1, Int((Float(steps) * Float(capPercent) / 100).rounded())) }

    var quietNow: Bool { Store.bool("quiet") && Bedtime.now }

    func set(level l: Int) {
        let v = Float(max(0, min(capSteps, l))) / Float(steps)
        slider?.setValue(v, animated: false)
        slider?.sendActions(for: .valueChanged)
    }

    func change(_ d: Int) -> String? {
        let cur = level
        if d > 0 && cur >= capSteps { return "That's as loud as it goes" }
        set(level: cur + d)
        return cur + d <= 0 ? "Volume is off" : nil
    }

    /// Set while "Ring the player" is sounding: it has to be loud, whatever the limit.
    var overrideCap = false

    func enforceCap() {
        if overrideCap { return }
        if level > capSteps { set(level: capSteps) }
    }
}

enum Bedtime {
    /// Between the bedtime start and end times (used by the volume limit and the black screen).
    static var now: Bool {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let s = Store.int("quiet_start"), e = Store.int("quiet_end")
        return s <= e ? (m >= s && m < e) : (m >= s || m < e)
    }

    static var darkOn: Bool { Store.bool("bedtime_dark") && now }
}
