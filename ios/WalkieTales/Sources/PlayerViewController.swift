import AVFoundation
import UIKit

/// The player screen. Same layout and behaviour as the Android player.
final class PlayerViewController: UIViewController {
    static let defaultAccent = UIColor(red: 0x6C / 255, green: 0x4C / 255, blue: 0xF1 / 255, alpha: 1)
    static let sleepMinutes = [0, 15, 30, 45, 60]

    let p = Player.shared
    var accent = PlayerViewController.defaultAccent
    var folderArt: UIImage?
    var folderAccent = PlayerViewController.defaultAccent
    var shownArtKey = 0
    var artToken = 0
    var sleepIdx = 0

    // views
    let backdrop = CAGradientLayer()
    let clock = UILabel(), battery = UILabel(), sleepLabel = UILabel()
    let moon = UIButton(type: .system), cog = UIButton(type: .system)
    let statusGroup = UIStackView()
    let artBox = UIView(), art = UIImageView(), status = PaddedLabel()
    let titleLabel = UILabel(), subtitle = UILabel(), eq = UIImageView()
    let seek = UISlider(), timePos = UILabel(), timeDur = UILabel()
    let prevBtn = RoundButton(), playBtn = RoundButton(), nextBtn = RoundButton()
    let volumeRow = UIStackView(), dots = UIStackView()
    let volDown = RoundButton(), volUp = RoundButton()
    let chipsRow = UIStackView()
    let libraryBtn = Chip(icon: "square.grid.3x3.fill", title: "Library")
    let tracksBtn = Chip(icon: "music.note.list", title: "Tracks")
    let blackout = UIView(), night = UIView(), nightClock = UILabel()
    var artSize: NSLayoutConstraint!
    var scrubbing = false

    // dimming / screen
    var dimmed = false
    var screenLocked = false
    var dimTimer: Timer?
    var savedBrightness: CGFloat = UIScreen.main.brightness
    var messageTimer: Timer?
    let server = RemoteServer()

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all } // first swipe from an edge does nothing
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUi()
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(batteryChanged), name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(batteryChanged), name: UIDevice.batteryStateDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: .libraryChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        p.onChange = { [weak self] in self?.updateUi() }
        p.onMessage = { [weak self] m, t in self?.flash(m, t) }
        p.onSleep = { [weak self] in DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self?.dimNow() } }
        view.addSubview(Volume.shared.view) // the hidden system volume slider
        server.api = { [weak self] r, b in try self?.remote(r, b) }
        syncRemote()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        if let last = Store.ud.string(forKey: "last"), Store.folders().contains(last) { p.open(last, play: false) }
        showIdleOrUpdate()
        applySettings()
        batteryChanged()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.findCovers(force: false) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdrop.frame = view.bounds
        let s = max(120, min(min(artBox.bounds.width - 16, artBox.bounds.height - 16), 360))
        if artSize.constant != s { artSize.constant = s }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        wake()
        if !UIAccessibility.isGuidedAccessEnabled && !Store.bool("guided_hint_shown") {
            Store.set("guided_hint_shown", true)
            flash("Grown-ups: triple-click the Home button to lock the player (Guided Access)", 8)
        }
    }

    @objc func appActive() { applySettings(); wake() }

    // MARK: UI construction

    func buildUi() {
        view.backgroundColor = .black
        backdrop.colors = [Art.shade(accent, 0.35).cgColor, UIColor(white: 0.04, alpha: 1).cgColor]
        view.layer.insertSublayer(backdrop, at: 0)

        let col = UIStackView()
        col.axis = .vertical
        col.alignment = .fill
        col.spacing = 0
        col.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            col.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            col.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            col.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),
        ])

        // top bar
        let top = UIStackView()
        top.alignment = .center
        clock.font = .systemFont(ofSize: 17, weight: .medium)
        clock.textColor = UIColor(white: 1, alpha: 0.85)
        battery.font = .systemFont(ofSize: 14)
        battery.textColor = UIColor(white: 1, alpha: 0.6)
        statusGroup.spacing = 12
        statusGroup.addArrangedSubview(clock)
        statusGroup.addArrangedSubview(battery)
        top.addArrangedSubview(statusGroup)
        top.addArrangedSubview(UIView())
        sleepLabel.font = .systemFont(ofSize: 14, weight: .bold)
        sleepLabel.textColor = UIColor(red: 1, green: 0.84, blue: 0.31, alpha: 1)
        top.addArrangedSubview(sleepLabel)
        configureIcon(moon, "moon.fill")
        moon.addTarget(self, action: #selector(cycleSleep), for: .touchUpInside)
        configureIcon(cog, "gearshape.fill")
        cog.alpha = 0.55
        cog.addTarget(self, action: #selector(cogTapped), for: .touchUpInside)
        cog.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(cogHeld(_:))))
        top.addArrangedSubview(moon)
        top.addArrangedSubview(cog)
        top.heightAnchor.constraint(equalToConstant: 46).isActive = true
        col.addArrangedSubview(top)

        // artwork (square, as big as the leftover space allows)
        col.addArrangedSubview(artBox)
        artBox.setContentHuggingPriority(.defaultLow, for: .vertical)
        artBox.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        art.translatesAutoresizingMaskIntoConstraints = false
        art.contentMode = .scaleAspectFill
        art.clipsToBounds = true
        art.layer.cornerRadius = 28
        art.layer.cornerCurve = .continuous
        art.isUserInteractionEnabled = true
        let shadow = UIView()
        shadow.translatesAutoresizingMaskIntoConstraints = false
        shadow.layer.shadowColor = UIColor.black.cgColor
        shadow.layer.shadowOpacity = 0.5
        shadow.layer.shadowRadius = 20
        shadow.layer.shadowOffset = CGSize(width: 0, height: 12)
        artBox.addSubview(shadow)
        shadow.addSubview(art)
        artSize = art.widthAnchor.constraint(equalToConstant: 240)
        NSLayoutConstraint.activate([
            shadow.centerXAnchor.constraint(equalTo: artBox.centerXAnchor),
            shadow.centerYAnchor.constraint(equalTo: artBox.centerYAnchor),
            art.leadingAnchor.constraint(equalTo: shadow.leadingAnchor), art.trailingAnchor.constraint(equalTo: shadow.trailingAnchor),
            art.topAnchor.constraint(equalTo: shadow.topAnchor), art.bottomAnchor.constraint(equalTo: shadow.bottomAnchor),
            artSize, art.heightAnchor.constraint(equalTo: art.widthAnchor),
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(artTapped))
        art.addGestureRecognizer(tap)
        for d in [UISwipeGestureRecognizer.Direction.left, .right, .up] {
            let s = UISwipeGestureRecognizer(target: self, action: #selector(artSwiped(_:)))
            s.direction = d
            art.addGestureRecognizer(s)
        }

        // messages float over the bottom of the cover
        status.font = .systemFont(ofSize: 15, weight: .bold)
        status.textColor = UIColor(red: 1, green: 0.88, blue: 0.51, alpha: 1)
        status.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 0.85)
        status.layer.cornerRadius = 18
        status.clipsToBounds = true
        status.numberOfLines = 3
        status.textAlignment = .center
        status.isHidden = true
        status.translatesAutoresizingMaskIntoConstraints = false
        artBox.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: artBox.centerXAnchor),
            status.bottomAnchor.constraint(equalTo: artBox.bottomAnchor, constant: -14),
            status.widthAnchor.constraint(lessThanOrEqualTo: artBox.widthAnchor, constant: -36),
        ])

        // folder name + track
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.65
        col.setCustomSpacing(12, after: artBox)
        col.addArrangedSubview(titleLabel)
        let sub = UIStackView()
        sub.alignment = .center
        sub.spacing = 10
        eq.image = UIImage(systemName: "waveform")
        eq.contentMode = .scaleAspectFit
        eq.widthAnchor.constraint(equalToConstant: 20).isActive = true
        subtitle.font = .systemFont(ofSize: 17)
        subtitle.textColor = UIColor(white: 1, alpha: 0.78)
        subtitle.lineBreakMode = .byTruncatingTail
        sub.addArrangedSubview(eq)
        sub.addArrangedSubview(subtitle)
        let subWrap = UIStackView(arrangedSubviews: [UIView(), sub, UIView()])
        subWrap.distribution = .equalCentering
        col.setCustomSpacing(4, after: titleLabel)
        col.addArrangedSubview(subWrap)

        // scrub bar
        seek.minimumTrackTintColor = .white
        seek.maximumTrackTintColor = UIColor(white: 1, alpha: 0.2)
        seek.setThumbImage(Self.dot(26, .white), for: .normal)
        seek.setThumbImage(Self.dot(32, .white), for: .highlighted)
        seek.addTarget(self, action: #selector(scrubStart), for: .touchDown)
        seek.addTarget(self, action: #selector(scrubMove), for: .valueChanged)
        seek.addTarget(self, action: #selector(scrubEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        seek.heightAnchor.constraint(equalToConstant: 40).isActive = true
        col.setCustomSpacing(10, after: subWrap)
        col.addArrangedSubview(seek)
        let times = UIStackView(arrangedSubviews: [timePos, UIView(), timeDur])
        for l in [timePos, timeDur] { l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular); l.textColor = UIColor(white: 1, alpha: 0.6) }
        col.addArrangedSubview(times)

        // transport
        let controls = UIStackView()
        controls.alignment = .center
        controls.spacing = 30
        prevBtn.setup(icon: "backward.end.fill", size: 68, color: UIColor(white: 1, alpha: 0.15), iconSize: 26)
        playBtn.setup(icon: "play.fill", size: 92, color: accent, iconSize: 38)
        nextBtn.setup(icon: "forward.end.fill", size: 68, color: UIColor(white: 1, alpha: 0.15), iconSize: 26)
        prevBtn.addTarget(self, action: #selector(prevTapped), for: .touchUpInside)
        prevBtn.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(prevHeld(_:))))
        playBtn.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        nextBtn.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        for b in [prevBtn, playBtn, nextBtn] { controls.addArrangedSubview(b) }
        let controlsWrap = UIStackView(arrangedSubviews: [UIView(), controls, UIView()])
        controlsWrap.distribution = .equalCentering
        col.setCustomSpacing(8, after: times)
        col.addArrangedSubview(controlsWrap)

        // volume
        volDown.setup(icon: "speaker.wave.1.fill", size: 48, color: UIColor(white: 1, alpha: 0.1), iconSize: 18)
        volUp.setup(icon: "speaker.wave.3.fill", size: 48, color: UIColor(white: 1, alpha: 0.1), iconSize: 18)
        volDown.addTarget(self, action: #selector(volDownTapped), for: .touchUpInside)
        volUp.addTarget(self, action: #selector(volUpTapped), for: .touchUpInside)
        dots.spacing = 8
        dots.alignment = .center
        volumeRow.alignment = .center
        volumeRow.addArrangedSubview(volDown)
        volumeRow.addArrangedSubview(UIView())
        volumeRow.addArrangedSubview(dots)
        volumeRow.addArrangedSubview(UIView())
        volumeRow.addArrangedSubview(volUp)
        col.setCustomSpacing(12, after: controlsWrap)
        col.addArrangedSubview(volumeRow)

        // Library / Tracks
        chipsRow.spacing = 12
        chipsRow.distribution = .fillEqually
        libraryBtn.addTarget(self, action: #selector(openLibrary), for: .touchUpInside)
        tracksBtn.addTarget(self, action: #selector(openTracks), for: .touchUpInside)
        chipsRow.addArrangedSubview(libraryBtn)
        chipsRow.addArrangedSubview(tracksBtn)
        chipsRow.heightAnchor.constraint(equalToConstant: 54).isActive = true
        col.setCustomSpacing(16, after: volumeRow)
        col.addArrangedSubview(chipsRow)

        // night light + black screen overlays
        for v in [night, blackout] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isHidden = true
            view.addSubview(v)
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: view.leadingAnchor), v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                                         v.topAnchor.constraint(equalTo: view.topAnchor), v.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        }
        blackout.backgroundColor = .black
        night.backgroundColor = UIColor(red: 0.28, green: 0.13, blue: 0.04, alpha: 1)
        nightClock.font = .systemFont(ofSize: 76, weight: .light)
        nightClock.textColor = UIColor(red: 1, green: 0.9, blue: 0.76, alpha: 0.55)
        nightClock.translatesAutoresizingMaskIntoConstraints = false
        night.addSubview(nightClock)
        NSLayoutConstraint.activate([nightClock.centerXAnchor.constraint(equalTo: night.centerXAnchor),
                                     nightClock.topAnchor.constraint(equalTo: night.safeAreaLayoutGuide.topAnchor, constant: 110)])
    }

    func configureIcon(_ b: UIButton, _ name: String) {
        b.setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)), for: .normal)
        b.tintColor = .white
        b.widthAnchor.constraint(equalToConstant: 46).isActive = true
        b.heightAnchor.constraint(equalToConstant: 46).isActive = true
    }

    static func dot(_ size: CGFloat, _ c: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            c.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).fill()
        }
    }

    // MARK: state → screen

    func showIdleOrUpdate() {
        if p.folder == nil { showIdle() } else { applyTheme(); updateUi() }
    }

    func showIdle() {
        art.image = Art.letter("♪", Self.defaultAccent)
        let name = Store.string("kid_name").trimmingCharacters(in: .whitespaces)
        titleLabel.text = name.isEmpty ? "Pick something!" : "\(Self.greeting()), \(name)!"
        subtitle.text = canBrowse ? "Press Library to choose" : "Ask a grown-up to pick something"
        timePos.text = ""; timeDur.text = ""
        seek.value = 0
        setSeekable(false)
        eq.isHidden = true
        setControls(enabled: false)
        renderTracksBtn()
        accent = Self.defaultAccent
        backdrop.colors = [Art.shade(accent, 0.35).cgColor, UIColor(white: 0.04, alpha: 1).cgColor]
        playBtn.backgroundColor = accent
        renderVolume()
    }

    static func greeting() -> String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 5 || h >= 19 { return "Sleep tight" }
        if h < 12 { return "Good morning" }
        if h < 17 { return "Good afternoon" }
        return "Good evening"
    }

    var lastFolder: String?
    var lastIndex = -1

    func updateUi() {
        guard let f = p.folder, let t = p.current else { showIdle(); lastFolder = nil; return }
        let newFolder = f != lastFolder
        if newFolder { lastFolder = f; applyTheme() }
        if newFolder || p.index != lastIndex { lastIndex = p.index; showTrackArt() }
        titleLabel.text = Store.label(f)
        var extra = ""
        if f != Store.ALL && Store.flag("shuffle", f, false) { extra += "  ·  shuffle" }
        if f != Store.ALL && Store.flag("repeat", f, false) { extra += "  ·  repeat" }
        let tn = t.name.caseInsensitiveCompare(titleLabel.text ?? "") == .orderedSame ? (p.isPlaying ? "Now playing" : "Tap ▶ to listen") : t.name
        subtitle.text = tn + extra
        eq.isHidden = false
        eq.tintColor = Art.tint(accent, 0.3)
        eq.alpha = p.isPlaying ? 1 : 0.4
        setControls(enabled: true)
        if p.isLive {
            setSeekable(false)
            seek.value = p.player == nil ? 0 : 1
            timePos.text = p.connecting ? "Connecting…" : (p.isPlaying ? "●  LIVE" : "LIVE")
            timeDur.text = ""
        } else if !scrubbing {
            let d = p.duration
            setSeekable(d > 0)
            seek.maximumValue = Float(max(d, 1))
            seek.value = Float(p.position)
            timePos.text = Self.fmt(p.position)
            timeDur.text = d > 0 ? Self.fmt(d) : ""
        }
        renderTracksBtn()
        renderVolume()
        renderSleep()
        updateKeepOn()
    }

    func applyTheme() {
        guard let f = p.folder else { return }
        let all = f == Store.ALL
        let cover = all ? nil : Art.folderCover(f)
        var a = all ? UIColor(red: 0.88, green: 0.33, blue: 0.6, alpha: 1) : Art.colorFor(f)
        if let c = cover { a = Art.dominant(c, fallback: a) }
        folderAccent = a
        folderArt = cover ?? Art.letter(all ? "★" : String(f.prefix(1)).uppercased(), a)
        shownArtKey = 0
        showArt(folderArt!, a)
    }

    func showArt(_ img: UIImage, _ a: UIColor) {
        accent = a
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        backdrop.colors = [Art.shade(a, 0.45).cgColor, UIColor(white: 0.04, alpha: 1).cgColor]
        CATransaction.commit()
        playBtn.backgroundColor = a
        UIView.transition(with: art, duration: 0.3, options: .transitionCrossDissolve, animations: { self.art.image = img })
        p.nowArt = img
        p.updateNowPlaying()
        renderVolume()
    }

    /// Each track's own picture while it plays; tracks without one show the folder's picture.
    func showTrackArt() {
        guard let t = p.current else { return }
        artToken += 1
        let token = artToken
        if t.live { if shownArtKey != 0, let fa = folderArt { shownArtKey = 0; showArt(fa, folderAccent) }; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = Art.embeddedData(t.source)
            let key = data.map { $0.hashValue | 1 } ?? 0
            let img = data.flatMap { UIImage(data: $0) }.map { Art.scaled($0, max: 900) }
            DispatchQueue.main.async {
                guard token == self.artToken, key != self.shownArtKey else { return }
                if let img = img {
                    self.shownArtKey = key
                    self.showArt(img, Art.dominant(img, fallback: self.folderAccent))
                } else if let fa = self.folderArt {
                    self.shownArtKey = 0
                    self.showArt(fa, self.folderAccent)
                }
            }
        }
    }

    func setControls(enabled: Bool) {
        prevBtn.alpha = enabled ? 1 : 0.35
        nextBtn.alpha = enabled ? 1 : 0.35
        playBtn.alpha = enabled ? 1 : 0.6
        playBtn.setIcon(p.isPlaying || (p.connecting) ? "pause.fill" : "play.fill")
    }

    func setSeekable(_ on: Bool) {
        seek.isEnabled = on
        seek.setThumbImage(on ? Self.dot(26, .white) : UIImage(), for: .normal)
    }

    var canBrowse: Bool { Store.bool("browse") || !Store.bool("cards") }

    func renderTracksBtn() {
        let allowed = Store.bool("track_list")
        let have = p.folder != nil && p.tracks.count > 1
        tracksBtn.isHidden = !allowed
        tracksBtn.isEnabled = have
        tracksBtn.alpha = have ? 1 : 0.4
        tracksBtn.setTitle(have ? "\(p.isLive ? "Stations" : "Tracks")  \(p.index + 1)/\(p.tracks.count)" : "Tracks")
        libraryBtn.isHidden = !canBrowse
        chipsRow.isHidden = tracksBtn.isHidden && libraryBtn.isHidden
    }

    var shownVolumeKey = -1

    func renderVolume() {
        let v = Volume.shared
        let cap = v.capSteps, cur = min(v.level, cap)
        let segs = min(cap, 10)
        let lit = cur == 0 ? 0 : max(1, Int((Float(cur * segs) / Float(cap)).rounded()))
        let key = segs * 1000 + lit
        if key == shownVolumeKey && dots.arrangedSubviews.count == segs {
            for (i, d) in dots.arrangedSubviews.enumerated() { d.backgroundColor = i < lit ? Art.tint(accent, 0.2) : UIColor(white: 1, alpha: 0.18) }
            return
        }
        shownVolumeKey = key
        dots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for i in 0..<segs {
            let d = UIView()
            d.layer.cornerRadius = 6.5
            d.backgroundColor = i < lit ? Art.tint(accent, 0.2) : UIColor(white: 1, alpha: 0.18)
            d.widthAnchor.constraint(equalToConstant: 13).isActive = true
            d.heightAnchor.constraint(equalToConstant: 13).isActive = true
            dots.addArrangedSubview(d)
        }
    }

    func renderSleep() {
        if let at = p.sleepAt {
            sleepLabel.text = "\(Int((at.timeIntervalSinceNow + 59) / 60))m"
            moon.tintColor = UIColor(red: 1, green: 0.84, blue: 0.31, alpha: 1)
            moon.alpha = 1
        } else {
            sleepLabel.text = ""
            moon.tintColor = .white
            moon.alpha = 0.5
        }
    }

    @objc func batteryChanged() {
        let d = UIDevice.current
        let pct = d.batteryLevel < 0 ? -1 : Int((d.batteryLevel * 100).rounded())
        let charging = d.batteryState == .charging || d.batteryState == .full
        battery.text = pct < 0 ? "" : "\(pct)%" + (charging ? " · charging" : "")
        battery.textColor = charging ? UIColor(red: 0.55, green: 0.89, blue: 0.55, alpha: 0.8) : (pct >= 0 && pct <= 15 ? UIColor(red: 1, green: 0.48, blue: 0.48, alpha: 1) : UIColor(white: 1, alpha: 0.6))
        updateKeepOn()
    }

    @objc func libraryChanged() {
        if presentedViewController is LibraryViewController { (presentedViewController as? LibraryViewController)?.reload() }
        findCovers(force: false)
    }

    func findCovers(force: Bool) {
        ArtFinder.run(force: force) { [weak self] in
            guard let self = self else { return }
            if self.p.folder != nil { self.applyTheme(); self.lastIndex = -1; self.updateUi() }
            (self.presentedViewController as? LibraryViewController)?.reload()
        }
    }

    var clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    func tick() {
        clock.text = clockFormatter.string(from: Date())
        nightClock.text = clockFormatter.string(from: Date())
        renderSleep()
        checkBedtime()
        if !scrubbing && p.isPlaying { updateUi() }
    }

    static func fmt(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: messages

    func flash(_ msg: String, _ seconds: TimeInterval) {
        messageTimer?.invalidate()
        status.text = msg
        status.isHidden = msg.isEmpty
        status.alpha = 1
        if !msg.isEmpty {
            messageTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                UIView.animate(withDuration: 0.2, animations: { self?.status.alpha = 0 }) { _ in self?.status.isHidden = true; self?.status.text = "" }
            }
        }
    }

    // MARK: actions

    @objc func playTapped() { if p.folder == nil { if canBrowse { openLibrary() } } else { p.toggle() } }
    @objc func prevTapped() { p.prev() }
    @objc func nextTapped() { p.next() }
    @objc func prevHeld(_ g: UILongPressGestureRecognizer) { if g.state == .began { p.restart() } }
    @objc func artTapped() { pop(); playTapped() }
    @objc func volDownTapped() { if let m = Volume.shared.change(-1) { flash(m, 1.5) }; renderVolume() }
    @objc func volUpTapped() { if let m = Volume.shared.change(1) { flash(m, 1.5) }; renderVolume() }
    @objc func cogTapped() { flash("Grown-ups: press and hold ⚙", 2) }
    @objc func cogHeld(_ g: UILongPressGestureRecognizer) { if g.state == .began { openSettings() } }

    @objc func artSwiped(_ g: UISwipeGestureRecognizer) {
        switch g.direction {
        case .left: nudge(-36); p.next()
        case .right: nudge(36); p.prev()
        case .up: openTracks()
        default: break
        }
    }

    @objc func cycleSleep() {
        sleepIdx = (sleepIdx + 1) % Self.sleepMinutes.count
        p.setSleep(minutes: Self.sleepMinutes[sleepIdx])
        renderSleep()
    }

    @objc func scrubStart() { scrubbing = true }
    @objc func scrubMove() { timePos.text = Self.fmt(Double(seek.value)) }
    @objc func scrubEnd() {
        scrubbing = false
        p.seek(Double(seek.value))
    }

    @objc func openLibrary() {
        guard canBrowse else { return }
        let l = LibraryViewController()
        l.onPick = { [weak self] f in
            guard let self = self else { return }
            if f == self.p.folder, self.p.player != nil { if !self.p.isPlaying { self.p.play() } } else { self.p.open(f, play: true) }
            self.pop()
        }
        l.modalPresentationStyle = .fullScreen
        present(l, animated: true)
    }

    @objc func openTracks() {
        guard Store.bool("track_list"), p.folder != nil, !p.tracks.isEmpty else { return }
        let t = TracksViewController(accent: accent, art: art.image)
        t.onPick = { [weak self] i in
            guard let self = self else { return }
            if i == self.p.index, self.p.player != nil { if !self.p.isPlaying { self.p.play() } } else { self.p.start(i, play: true) }
        }
        if let s = t.sheetPresentationController {
            s.detents = [.medium(), .large()]
            s.prefersGrabberVisible = true
            s.preferredCornerRadius = 28
        }
        present(t, animated: true)
    }

    func openSettings() {
        let show = { [weak self] in
            guard let self = self else { return }
            let s = SettingsViewController(style: .insetGrouped)
            s.owner = self
            let nav = UINavigationController(rootViewController: s)
            nav.modalPresentationStyle = .fullScreen
            self.present(nav, animated: true)
        }
        if !Store.bool("gate") { show(); return }
        let a = Int.random(in: 11...49), b = Int.random(in: 11...49)
        let alert = UIAlertController(title: "Grown-ups only", message: "What is \(a) + \(b)?", preferredStyle: .alert)
        alert.addTextField { $0.keyboardType = .numberPad; $0.textAlignment = .center; $0.font = .systemFont(ofSize: 24) }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            if alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) == String(a + b) { show() }
            else { self?.flash("Not quite!", 2); self?.shake() }
        })
        present(alert, animated: true)
    }

    // MARK: little animations

    func pop() {
        UIView.animate(withDuration: 0.11, animations: { self.art.transform = CGAffineTransform(scaleX: 1.08, y: 1.08) }) { _ in
            UIView.animate(withDuration: 0.22) { self.art.transform = .identity }
        }
    }

    func nudge(_ dx: CGFloat) {
        UIView.animate(withDuration: 0.09, animations: { self.art.transform = CGAffineTransform(translationX: dx, y: 0) }) { _ in
            UIView.animate(withDuration: 0.18) { self.art.transform = .identity }
        }
    }

    func shake() {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, 14, -14, 8, -8, 0]
        a.duration = 0.42
        art.layer.add(a, forKey: "shake")
    }

    // MARK: settings / remote

    func applySettings() {
        volumeRow.isHidden = !Store.bool("show_volume")
        statusGroup.isHidden = !Store.bool("show_status")
        nightClock.isHidden = !Store.bool("night_clock")
        renderTracksBtn()
        if p.folder == nil { showIdle() } else { updateUi() }
        updateKeepOn()
        Volume.shared.enforceCap()
        syncRemote()
    }

    func syncRemote() {
        if Store.bool("remote") { server.start() } else { server.stop() }
    }

    /// Keep the screen on only when asked; otherwise iOS Auto-Lock switches it off (music keeps playing).
    func updateKeepOn() {
        let mode = Store.int("screen_on")
        let charging = [.charging, .full].contains(UIDevice.current.batteryState)
        let on = !screenLocked && (mode == 1 || (mode == 2 && p.isPlaying) || (Store.bool("cards") && (charging || Bedtime.darkOn)))
        if UIApplication.shared.isIdleTimerDisabled != on { UIApplication.shared.isIdleTimerDisabled = on }
    }
}

// MARK: - small reusable views

final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 9, left: 16, bottom: 9, right: 16)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines n: Int) -> CGRect {
        let r = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: n)
        return r.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }
}

final class RoundButton: UIButton {
    private var iconSize: CGFloat = 22

    func setup(icon: String, size: CGFloat, color: UIColor, iconSize: CGFloat) {
        self.iconSize = iconSize
        backgroundColor = color
        layer.cornerRadius = size / 2
        tintColor = .white
        setIcon(icon)
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)
    }

    func setIcon(_ name: String) {
        setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: iconSize, weight: .bold)), for: .normal)
    }

    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: 0.1) { self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity } }
    }
}

final class Chip: UIButton {
    private let label = UILabel()

    init(icon: String, title: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 1, alpha: 0.14)
        layer.cornerRadius = 27
        let img = UIImageView(image: UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)))
        img.tintColor = .white
        label.text = title
        label.font = .systemFont(ofSize: 17, weight: .bold)
        label.textColor = .white
        let s = UIStackView(arrangedSubviews: [img, label])
        s.spacing = 10
        s.alignment = .center
        s.isUserInteractionEnabled = false
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([s.centerXAnchor.constraint(equalTo: centerXAnchor), s.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ t: String) { label.text = t }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.7 : (isEnabled ? 1 : 0.4) } }
}
