import UIKit
import AVFoundation

/// Grown-up settings (behind the cog and the quick sum). Like the Android player and the remote's Settings tab:
/// a short menu of topics, each opening its own page, with the same order and wording.
final class SettingsViewController: UITableViewController, UISearchResultsUpdating {
    weak var owner: PlayerViewController?
    /// nil = the menu; otherwise the page shown ("library", "cards", "sound", …).
    var page: String?

    enum Row {
        case menu(String, String, () -> String, String)       // SF Symbol, title, summary, page to open
        case toggle(String, String?, String)                 // title, subtitle, key
        case value(String, () -> String, () -> Void)        // title, current value, tap
        case slider(String, String)                          // title, key (10–100 %)
        case info(String, String?)
    }

    private var sections: [(String?, [Row])] = []

    convenience init(page: String?) {
        self.init(style: .insetGrouped)
        self.page = page
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = Self.titles[page ?? ""] ?? "Grown-up settings"
        overrideUserInterfaceStyle = .dark
        navigationController?.overrideUserInterfaceStyle = .dark
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        if page == nil { // search every setting from the menu
            navigationItem.searchController = search
            navigationItem.hidesSearchBarWhenScrolling = false
            definesPresentationContext = true
        }
        build()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload() // the menu's summaries follow what was changed on a page
    }

    @objc private func done() {
        let o = owner
        navigationController?.dismiss(animated: true) { o?.applySettings(); o?.wake() }
    }

    /// Every page in menu order, with everyday words that should find it in search (same as Android and the remote).
    static let pages: [(id: String, title: String, words: String)] = [
        ("child", "Your child", "kid name son daughter"),
        ("library", "Library", "folders albums covers art pictures shuffle"),
        ("cards", "Cards", "nfc tag tap link"),
        ("sound", "Sound", "volume loud quiet fade"),
        ("headphones", "Headphones", "bluetooth earphones earbuds pair speaker"),
        ("musictime", "Music time", "limit daily hours minutes screen time allowance"),
        ("messages", "Messages", "voice record mum dad mom story microphone"),
        ("bedtime", "Bedtime", "night sleep quiet times evening"),
        ("nightlight", "Night light", "glow orange green ok to wake morning lamp"),
        ("screen", "Screen", "display brightness dim sleep timeout"),
        ("safety", "Safety", "pin password lock guided access sum check"),
        ("phone", "Phone", "iphone settings wifi auto-lock"),
        ("remote", "Remote control", "wifi pin address app"),
        ("about", "About", "version update free space storage"),
    ]
    static var titles: [String: String] { Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0.title) }) }

    private var query = ""
    private lazy var search: UISearchController = {
        let s = UISearchController(searchResultsController: nil)
        s.searchResultsUpdater = self
        s.obscuresBackgroundDuringPresentation = false
        s.hidesNavigationBarDuringPresentation = false
        s.searchBar.placeholder = "Search settings"
        return s
    }()

    func updateSearchResults(for s: UISearchController) {
        let q = (s.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        if q == query { return }
        query = q
        reload()
    }

    private func build() {
        if page == nil && !query.isEmpty { buildResults(); return }
        sections = page.map { pageSections($0) } ?? menuSections()
    }

    /// Matching rows from every page (they work right here), under "Page › Section".
    private func buildResults() {
        let words = query.lowercased().split(separator: " ").map(String.init)
        func hit(_ text: String) -> Bool { let t = text.lowercased(); return words.allSatisfy { t.contains($0) } }
        var out: [(String?, [Row])] = []
        for p in Self.pages {
            let whole = hit(p.title + " " + p.words)
            for (head, rows) in pageSections(p.id) {
                let keep = rows.filter { whole || hit(Self.text($0)) }
                if !keep.isEmpty { out.append((p.title + (head.map { "  ›  " + $0 } ?? ""), keep)) }
            }
        }
        if out.isEmpty { out = [(nil, [.info("Nothing called “\(query)”", "Try a word like volume, PIN, night or limit.")])] }
        sections = out
    }

    private static func text(_ r: Row) -> String {
        switch r {
        case let .menu(_, t, s, _): return t + " " + s()
        case let .toggle(t, s, _): return t + " " + (s ?? "")
        case let .value(t, v, _): return t + " " + v()
        case let .slider(t, _): return t
        case let .info(t, s): return t + " " + (s ?? "")
        }
    }

    private func menuSections() -> [(String?, [Row])] {
        [
            (nil, [.menu("person.fill", "Your child", { let n = Store.string("kid_name"); return n.isEmpty ? "Not set" : n }, "@name")]),
            ("Listening", [
                .menu("square.grid.3x3.fill", "Library", { let n = Store.folders().count; return "\(n) " + (n == 1 ? "folder" : "folders") }, "library"),
                .menu("creditcard.fill", "Cards", { "Not on iPhone yet" }, "cards"),
                .menu("speaker.wave.2.fill", "Sound", { "Maximum volume \(Store.int("max_volume"))%" }, "sound"),
                .menu("headphones", "Headphones", { Store.bool("headphones_button") ? "Button on the player" : "Button hidden" }, "headphones"),
            ]),
            ("Family", [
                .menu("timer", "Music time", { let m = Store.int("daily_limit"); return m <= 0 ? "No daily limit" : Self.limitLabel(m) + " a day" }, "musictime"),
                .menu("mic.fill", "Messages", { let n = Self.messageCount(); return n == 0 ? "Record one for them" : "\(n) " + (n == 1 ? "message" : "messages") }, "messages"),
            ]),
            ("Night", [
                .menu("moon.fill", "Bedtime", { Self.time(Store.int("quiet_start")) + " to " + Self.time(Store.int("quiet_end")) }, "bedtime"),
                .menu("lightbulb.fill", "Night light", { !Store.bool("night_light") ? "Off" : Store.bool("ok_to_wake") ? "On  ·  green at " + Self.time(Store.int("quiet_end")) : "On" }, "nightlight"),
                .menu("iphone", "Screen", { Self.screenSummary() }, "screen"),
            ]),
            ("Phone and safety", [
                .menu("shield.fill", "Safety", { !Store.bool("gate") ? "Grown-up check off" : Store.gatePin().isEmpty ? "Grown-up sum on" : "Grown-up PIN on" }, "safety"),
                .menu("power", "Phone", { "iPhone settings" }, "phone"),
                .menu("wifi", "Remote control", { Store.bool("remote") ? "On" : "Off" }, "remote"),
                .menu("info.circle.fill", "About", { "WalkieTales " + Self.version }, "about"),
            ]),
        ]
    }

    private static let limits = [(0, "No limit"), (30, "30 minutes"), (60, "1 hour"), (90, "90 minutes"), (120, "2 hours"), (180, "3 hours")]
    static func limitLabel(_ m: Int) -> String { limits.first { $0.0 == m }?.1 ?? "\(m) minutes" }

    static func messageCount() -> Int {
        let fs = (try? FileManager.default.contentsOfDirectory(atPath: Store.dir(voiceFolder).path)) ?? []
        return fs.filter { ["mp3", "m4a", "aac", "wav"].contains(($0 as NSString).pathExtension.lowercased()) }.count
    }

    private func pageSections(_ p: String) -> [(String?, [Row])] {
        switch p {
        case "child":
            return [(nil, [.value("Child's name", { let n = Store.string("kid_name"); return n.isEmpty ? "Not set" : n }, { [weak self] in self?.editName() })])]
        case "library": return librarySections()
        case "cards":
            return [(nil, [.info("Cards aren't on the iPhone player yet",
                                 "An iPhone only reads NFC cards inside a scan pop-up, so there's no tap-and-play like on Android. Use the Library instead.")])]
        case "sound":
            return [
                (nil, [.slider("Maximum volume", "max_volume")]),
                (nil, [.toggle("Fade in", "Starts quietly and gets louder", "fade_in")]),
                (nil, [.menu("moon.fill", "Bedtime volume", { "In Bedtime" }, "bedtime")]),
            ]
        case "headphones":
            return [(nil, [
                .toggle("Headphones button", "Picks headphones or the speaker from the player", "headphones_button"),
                .value("Pair new headphones", { "iPhone Settings → Bluetooth" }, { Self.openSettings("Bluetooth") }),
                .info("Pairing needs Guided Access off", "Triple-click the Home button to leave it, pair in Settings, then start Guided Access again."),
            ])]
        case "musictime":
            var s: [(String?, [Row])] = [(nil, [
                .value("Daily listening limit", { Self.limitLabel(Store.int("daily_limit")) }, { [weak self] in self?.pickLimit() }),
                .info("Sleep sounds never count", "When it's used up, the player says “Music time is finished” until tomorrow"),
            ])]
            if Store.int("daily_limit") > 0 {
                s.append(("Today", [
                    .value("Today", { if let a = Limit.allowedToday { return "\(Int(Limit.listenedMs / 60_000)) of \(a) minutes" }; return "No limit today" }, {}),
                    .value("+30 minutes today", { "" }, { [weak self] in Limit.add(30); self?.reload() }),
                    .value("No limit today", { "" }, { [weak self] in Limit.offToday(); self?.reload() }),
                ]))
            }
            return s
        case "messages":
            var rows: [Row] = [.value("Record a message", { "Goodnight or a story" }, { [weak self] in self?.recordMessage() })]
            let n = Self.messageCount()
            if n > 0 { rows.append(.value("Play the messages", { "\(n) in “\(Self.voiceFolder)”" }, { [weak self] in self?.playNow(Self.voiceFolder) })) }
            return [(nil, rows), (nil, [.info("From your phone", "On the remote, tap Message and hold the red button to record")])]
        case "bedtime":
            return [
                ("Times", [
                    .value("Bedtime starts", { Self.time(Store.int("quiet_start")) }, { [weak self] in self?.pickTime("quiet_start") }),
                    .value("Bedtime ends", { Self.time(Store.int("quiet_end")) }, { [weak self] in self?.pickTime("quiet_end") }),
                ]),
                ("During bedtime", [
                    .toggle("Screen off at bedtime", "Goes black 30 seconds after the last touch", "bedtime_dark"),
                    .toggle("Quieter at bedtime", nil, "quiet"),
                    .slider("Bedtime maximum volume", "quiet_volume"),
                ]),
                (nil, [.menu("lightbulb.fill", "Night light", { "Orange through the night, green at wake-up" }, "nightlight")]),
            ]
        case "nightlight":
            return [
                (nil, [
                    .toggle("Night light", "A warm orange glow all through bedtime, instead of a black screen. Keep it on the charger", "night_light"),
                    .toggle("Clock on the night light", nil, "night_clock"),
                ]),
                ("OK to wake", [
                    .toggle("OK to wake", "The night light turns green when bedtime ends (\(Self.time(Store.int("quiet_end")))), so they know they can get up", "ok_to_wake"),
                    .value("Stays green for", { Self.cycleLabel("wake_glow_mins", [30, 60, 90, 120], ["30 minutes", "1 hour", "90 minutes", "2 hours"]) },
                           { [weak self] in self?.cycle("wake_glow_mins", [30, 60, 90, 120]) }),
                ]),
                (nil, [.menu("moon.fill", "Bedtime times", { Self.time(Store.int("quiet_start")) + " to " + Self.time(Store.int("quiet_end")) }, "bedtime")]),
            ]
        case "screen":
            return [
                ("Sleeping", [
                    .value("Dim the screen after", { Self.cycleLabel("dim_after", [30, 90, 300, 0], ["30 seconds", "90 seconds", "5 minutes", "Never"]) },
                           { [weak self] in self?.cycle("dim_after", [30, 90, 300, 0]) }),
                    .value("Keep the screen on", { Self.cycleLabel("screen_on", [0, 2, 1], ["No", "While playing", "Always"]) },
                           { [weak self] in self?.cycle("screen_on", [0, 2, 1]) }),
                    .info("Screen turns off after", "Set Auto-Lock in iPhone Settings → Display & Brightness"),
                ]),
                ("On the player", [
                    .toggle("Clock and battery", nil, "show_status"),
                    .toggle("Volume buttons on screen", nil, "show_volume"),
                    .toggle("Library button", nil, "browse"),
                    .toggle("Tracks button", nil, "track_list"),
                ]),
            ]
        case "safety":
            return [(nil, [
                .toggle("Grown-up check before settings", Store.gatePin().isEmpty ? "A quick sum" : "The grown-up PIN", "gate"),
                .value("Grown-up PIN", { Store.gatePin().isEmpty ? "Not set" : "Set" }, { [weak self] in self?.editGatePin() }),
                .info("Lock to this app", UIAccessibility.isGuidedAccessEnabled ? "On (Guided Access)" : "Triple-click the Home button to start Guided Access"),
            ])]
        case "phone":
            return [(nil, [
                .value("iPhone settings", { "Wi-Fi, Bluetooth, brightness" }, { Self.openSettings(nil) }),
                .info("Auto-Lock", "iPhone Settings → Display & Brightness"),
            ])]
        case "remote":
            return [
                (nil, [.toggle("Remote control", "Control this player from any phone, tablet or computer on the same Wi-Fi", "remote")]),
                ("Connect", [
                    .info("Address", RemoteServer.address ?? "Not on Wi-Fi"),
                    .info("Secure address", RemoteServer.ip.map { "https://\($0):\(RemoteServer.httpsPort)  ·  for voice messages (accept the warning once)" } ?? "Not on Wi-Fi"),
                    .info("PIN", RemoteServer.pin),
                    .value("Change PIN", { "" }, { [weak self] in
                        self?.confirm("Make a new PIN?", "Remote controls will need the new PIN.") { RemoteServer.newPin(); self?.reload() }
                    }),
                ]),
                ("How to use it", [
                    .info("1.  Join the same Wi-Fi", "Your phone needs to be on the same Wi-Fi as this player"),
                    .info("2.  Open the address", RemoteServer.ip.map { "Type \($0):\(RemoteServer.port) into Safari or Chrome on your phone" }
                          ?? "Connect this player to Wi-Fi first, then its address shows here"),
                    .info("3.  Enter the PIN", RemoteServer.pin + "  ·  each phone asks once"),
                    .info("4.  Keep it on your home screen", "iPhone: Share → Add to Home Screen.  Android: ⋮ → Add to Home screen"),
                    .info("Voice messages", "Open the secure address instead and accept the warning once (it's this player's own certificate). Then tap Message and hold the red button"),
                ]),
                ("All your players in one place", [
                    .info("A remote for every player", "Run the WalkieTales remote on a home server (Docker) for one page that controls all your players. See github.com/jaso1000/walkie-tales"),
                ]),
            ]
        case "about":
            return [
                (nil, [.info("WalkieTales " + Self.version + " for iPhone", Self.freeSpace())]),
                ("Updates", [.info("New versions", "Install them with TrollStore. Android players update from the remote.")]),
            ]
        default: return menuSections()
        }
    }

    private func librarySections() -> [(String?, [Row])] {
        let folders = Store.folders()
        var lib: [Row] = folders.map { f in .value(f, { Self.folderSummary(f) }, { [weak self] in self?.folderOptions(f) }) }
        if folders.isEmpty { lib.append(.info("No folders yet", "Add music from the remote, or with the Files app (On My iPhone → WalkieTales → Cards)")) }
        lib.append(.value("Shuffle everything", { "" }, { [weak self] in self?.playNow(Store.ALL) }))
        return [
            ("Folders", lib),
            ("Covers", [.toggle("Find missing covers online", nil, "find_art")]),
        ]
    }

    private func reload() { build(); tableView.reloadData() }

    // MARK: voice messages (a grown-up records into the "Messages" folder, same as Android and the remote)

    static let voiceFolder = Messages.folder
    private var recorder: AVAudioRecorder?
    private var recTimer: Timer?
    private var listen: AVAudioPlayer?
    private var recURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("message.m4a") }

    private func recordMessage() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] ok in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !ok { self.say("The microphone is off for WalkieTales. Turn it on in iPhone Settings → Privacy → Microphone."); return }
                let a = UIAlertController(title: "Record a message", message: "It goes into the “\(Self.voiceFolder)” folder. Tap Record and start talking.", preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                a.addAction(UIAlertAction(title: "Record", style: .default) { [weak self] _ in self?.startRecording() })
                self.present(a, animated: true)
            }
        }
    }

    private func startRecording() {
        Player.shared.pause()
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try s.setActive(true)
            let r = try AVAudioRecorder(url: recURL, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                                                             AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000])
            guard r.record(forDuration: 3600) else { throw NSError(domain: "rec", code: 1) }
            recorder = r
        } catch {
            restoreSession()
            say("The microphone didn’t start.")
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        let a = UIAlertController(title: "Recording…", message: "● 0:00", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.stopRecorder(); try? FileManager.default.removeItem(at: self?.recURL ?? URL(fileURLWithPath: "/")) })
        a.addAction(UIAlertAction(title: "Stop", style: .default) { [weak self] _ in self?.finishRecording() })
        present(a, animated: true)
        recTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak a] _ in
            guard let t = self?.recorder?.currentTime else { return }
            a?.message = String(format: "● %d:%02d", Int(t) / 60, Int(t) % 60)
        }
    }

    @discardableResult private func stopRecorder() -> TimeInterval {
        recTimer?.invalidate(); recTimer = nil
        let t = recorder?.currentTime ?? 0
        recorder?.stop(); recorder = nil
        restoreSession()
        UIApplication.shared.isIdleTimerDisabled = false
        owner?.applySettings() // the player's own keep-awake rules
        return t
    }

    private func restoreSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
    }

    private func finishRecording() {
        guard stopRecorder() > 0.8 else {
            try? FileManager.default.removeItem(at: recURL)
            let a = UIAlertController(title: nil, message: "That was too short. Try again?", preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            a.addAction(UIAlertAction(title: "Record", style: .default) { [weak self] _ in self?.startRecording() })
            present(a, animated: true)
            return
        }
        askName()
    }

    private func askName() {
        let a = UIAlertController(title: "Give it a name", message: nil, preferredStyle: .alert)
        a.addTextField { $0.placeholder = "e.g. Goodnight, love you!"; $0.autocapitalizationType = .sentences }
        a.addAction(UIAlertAction(title: "Listen", style: .default) { [weak self, weak a] _ in
            guard let self = self else { return }
            self.listen = try? AVAudioPlayer(contentsOf: self.recURL)
            self.listen?.play()
            let typed = a?.textFields?.first?.text
            self.askName()
            (self.presentedViewController as? UIAlertController)?.textFields?.first?.text = typed
        })
        a.addAction(UIAlertAction(title: "Throw away", style: .destructive) { [weak self] _ in
            self?.listen?.stop(); try? FileManager.default.removeItem(at: self?.recURL ?? URL(fileURLWithPath: "/"))
        })
        a.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak a] _ in
            self?.listen?.stop(); self?.saveRecording(a?.textFields?.first?.text ?? "")
        })
        present(a, animated: true)
    }

    private func saveRecording(_ title: String) {
        var n = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if n.isEmpty { let f = DateFormatter(); f.dateFormat = "d MMM h.mm a"; n = "Message " + f.string(from: Date()) }
        let dir = Store.dir(Self.voiceFolder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = Messages.unique(in: dir, n + ".m4a")
        do { try FileManager.default.moveItem(at: recURL, to: out); Messages.ensureCover(); say("Saved in “\(Self.voiceFolder)” 💌") }
        catch { say("Couldn’t save it.") }
    }

    private func pickLimit() {
        let a = UIAlertController(title: "Daily listening limit", message: "Sleep sounds never count.", preferredStyle: .alert)
        for (m, label) in [(0, "No limit"), (30, "30 minutes"), (60, "1 hour"), (90, "90 minutes"), (120, "2 hours"), (180, "3 hours")] {
            a.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in Store.set("daily_limit", m); self?.reload() })
        }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(a, animated: true)
    }

    /// Set, change or remove the grown-up PIN: asked for instead of the sum before settings.
    private func editGatePin() {
        let a = UIAlertController(title: "Grown-up PIN",
                                  message: "Asked for instead of the sum before settings. If it's forgotten, it can be removed from the remote.",
                                  preferredStyle: .alert)
        for hint in ["New PIN (4 to 8 numbers)", "Same PIN again"] {
            a.addTextField { $0.placeholder = hint; $0.keyboardType = .numberPad; $0.isSecureTextEntry = true; $0.textAlignment = .center }
        }
        a.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            let p = a.textFields?[0].text?.trimmingCharacters(in: .whitespaces) ?? ""
            let q = a.textFields?[1].text?.trimmingCharacters(in: .whitespaces) ?? ""
            guard p.range(of: "^[0-9]{4,8}$", options: .regularExpression) != nil else { self?.say("Use 4 to 8 numbers"); return }
            guard p == q else { self?.say("The two PINs don't match"); return }
            Store.set("gate_pin", p); Store.set("gate", true)
            self?.reload()
        })
        if !Store.gatePin().isEmpty {
            a.addAction(UIAlertAction(title: "Remove (back to the sum)", style: .destructive) { [weak self] _ in
                Store.ud.removeObject(forKey: "gate_pin"); self?.reload()
            })
        }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(a, animated: true)
    }

    private func say(_ s: String) {
        let a = UIAlertController(title: nil, message: s, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }

    override func numberOfSections(in t: UITableView) -> Int { sections.count }
    override func tableView(_ t: UITableView, titleForHeaderInSection s: Int) -> String? { sections[s].0 }
    override func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { sections[s].1.count }

    override func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.accessoryView = nil
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 0
        switch sections[ip.section].1[ip.row] {
        case let .menu(symbol, title, summary, _):
            cell.imageView?.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
            cell.imageView?.tintColor = UIColor(red: 0.69, green: 0.6, blue: 1, alpha: 1)
            cell.textLabel?.text = title
            cell.detailTextLabel?.text = summary()
            cell.selectionStyle = .default
            cell.accessoryType = .disclosureIndicator
        case let .toggle(title, sub, key):
            cell.textLabel?.text = title
            cell.detailTextLabel?.text = sub
            let sw = UISwitch()
            sw.isOn = Store.bool(key)
            sw.addAction(UIAction { [weak self] _ in Store.set(key, sw.isOn); self?.owner?.applySettings() }, for: .valueChanged)
            cell.accessoryView = sw
        case let .value(title, value, _):
            cell.textLabel?.text = title
            cell.detailTextLabel?.text = value()
            cell.selectionStyle = .default
            cell.accessoryType = .disclosureIndicator
        case let .slider(title, key):
            cell.textLabel?.text = title
            cell.detailTextLabel?.text = "\(Store.int(key))%"
            let sl = UISlider(frame: CGRect(x: 0, y: 0, width: 150, height: 30))
            sl.minimumValue = 10
            sl.maximumValue = 100
            sl.value = Float(Store.int(key))
            sl.addAction(UIAction { _ in
                let v = Int((sl.value / 5).rounded()) * 5
                Store.set(key, v)
                cell.detailTextLabel?.text = "\(v)%"
            }, for: .valueChanged)
            sl.addAction(UIAction { [weak self] _ in self?.owner?.applySettings() }, for: .touchUpInside)
            cell.accessoryView = sl
        case let .info(title, sub):
            cell.textLabel?.text = title
            cell.detailTextLabel?.text = sub
        }
        return cell
    }

    override func tableView(_ t: UITableView, didSelectRowAt ip: IndexPath) {
        switch sections[ip.section].1[ip.row] {
        case let .menu(_, _, _, target):
            if target == "@name" { editName(); break }
            let next = SettingsViewController(page: target)
            next.owner = owner
            navigationController?.pushViewController(next, animated: true)
        case let .value(_, _, tap): tap()
        default: break
        }
        t.deselectRow(at: ip, animated: true)
    }

    // MARK: actions

    private func editName() {
        let a = UIAlertController(title: "Child's name", message: nil, preferredStyle: .alert)
        a.addTextField { $0.text = Store.string("kid_name"); $0.autocapitalizationType = .words }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            Store.set("kid_name", a.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? "")
            self?.reload()
        })
        present(a, animated: true)
    }

    private func pickTime(_ key: String) {
        let vc = UIViewController()
        let picker = UIDatePicker()
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .wheels
        let m = Store.int(key)
        picker.date = Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        vc.view = picker
        vc.preferredContentSize = CGSize(width: 320, height: 216)
        let a = UIAlertController(title: key == "quiet_start" ? "Bedtime starts" : "Bedtime ends", message: nil, preferredStyle: .actionSheet)
        a.setValue(vc, forKey: "contentViewController")
        a.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            let c = Calendar.current.dateComponents([.hour, .minute], from: picker.date)
            Store.set(key, (c.hour ?? 0) * 60 + (c.minute ?? 0))
            self?.reload()
        })
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(a, animated: true)
    }

    private func cycle(_ key: String, _ values: [Int]) {
        let i = values.firstIndex(of: Store.int(key)) ?? 0
        Store.set(key, values[(i + 1) % values.count])
        owner?.applySettings()
        reload()
    }

    private func folderOptions(_ f: String) {
        let a = UIAlertController(title: f, message: Self.folderSummary(f), preferredStyle: .actionSheet)
        for (key, label, def) in [("shuffle", "Shuffle", false), ("repeat", "Repeat when finished", false), ("resume", "Carry on where it stopped", true)] {
            let on = Store.flag(key, f, def)
            a.addAction(UIAlertAction(title: (on ? "✓ " : "") + label, style: .default) { [weak self] _ in
                Store.set(key + ":" + f, !on)
                self?.reload()
            })
        }
        a.addAction(UIAlertAction(title: "Start over", style: .default) { [weak self] _ in Store.savePosition(f, index: 0, ms: 0); self?.reload() })
        a.addAction(UIAlertAction(title: "Play now", style: .default) { [weak self] _ in self?.playNow(f) })
        a.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(a, animated: true)
    }

    private func playNow(_ f: String) {
        let o = owner
        navigationController?.dismiss(animated: true) { Player.shared.open(f, play: true); o?.applySettings() }
    }

    private func confirm(_ title: String, _ msg: String, _ yes: @escaping () -> Void) {
        let a = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Yes", style: .default) { _ in yes() })
        present(a, animated: true)
    }

    /// iPhone Settings, at a section if iOS allows it (TrollStore apps can use the Settings URL scheme).
    static func openSettings(_ section: String?) {
        if let s = section, let u = URL(string: "App-prefs:" + s) {
            UIApplication.shared.open(u) { ok in
                if !ok, let a = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(a) }
            }
            return
        }
        if let a = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(a) }
    }

    // MARK: helpers

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    static func screenSummary() -> String {
        switch Store.int("screen_on") {
        case 1: return "Always on"
        case 2: return "On while playing, then Auto-Lock"
        default: return "Off with Auto-Lock"
        }
    }

    static func folderSummary(_ f: String) -> String {
        let n = Store.listTracks(f).count
        var s = Store.isLiveOnly(f) ? (n == 1 ? "live radio" : "\(n) radio stations") : "\(n) " + (n == 1 ? "track" : "tracks")
        if Store.flag("shuffle", f, false) { s += "  ·  shuffle" }
        if Store.flag("repeat", f, false) { s += "  ·  repeat" }
        if !Store.flag("resume", f, true) { s += "  ·  always from the start" }
        return s
    }

    static func time(_ mins: Int) -> String {
        let d = Calendar.current.date(bySettingHour: mins / 60, minute: mins % 60, second: 0, of: Date()) ?? Date()
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: d)
    }

    static func cycleLabel(_ key: String, _ values: [Int], _ labels: [String]) -> String {
        labels[values.firstIndex(of: Store.int(key)) ?? 0]
    }

    static func freeSpace() -> String {
        guard let v = try? Store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let c = v.volumeAvailableCapacityForImportantUsage else { return "" }
        return String(format: "%.1f GB free", Double(c) / 1e9)
    }
}
