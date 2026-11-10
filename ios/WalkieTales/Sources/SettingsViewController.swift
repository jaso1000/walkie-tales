import UIKit

/// Grown-up settings (behind the cog and the quick sum). Like the Android player and the remote's Settings tab:
/// a short menu of topics, each opening its own page, with the same order and wording.
final class SettingsViewController: UITableViewController {
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

    static let titles = ["library": "Library", "cards": "Cards", "sound": "Sound", "bedtime": "Bedtime", "screen": "Screen",
                         "safety": "Safety", "remote": "Remote control", "about": "About"]

    private func build() {
        switch page {
        case "library": buildLibrary()
        case "cards":
            sections = [(nil, [.info("Cards aren't on the iPhone player yet",
                                     "An iPhone only reads NFC cards inside a scan pop-up, so there's no tap-and-play like on Android. Use the Library instead.")])]
        case "sound": buildSound()
        case "bedtime":
            sections = [
                ("Times", [
                    .value("Bedtime starts", { Self.time(Store.int("quiet_start")) }, { [weak self] in self?.pickTime("quiet_start") }),
                    .value("Bedtime ends", { Self.time(Store.int("quiet_end")) }, { [weak self] in self?.pickTime("quiet_end") }),
                ]),
                ("During bedtime", [
                    .toggle("Screen off at bedtime", "Goes black 30 seconds after the last touch", "bedtime_dark"),
                    .toggle("Quieter at bedtime", nil, "quiet"),
                    .slider("Bedtime maximum volume", "quiet_volume"),
                ]),
            ]
        case "screen":
            sections = [
                ("Sleeping", [
                    .value("Dim the screen after", { Self.cycleLabel("dim_after", [30, 90, 300, 0], ["30 seconds", "90 seconds", "5 minutes", "Never"]) },
                           { [weak self] in self?.cycle("dim_after", [30, 90, 300, 0]) }),
                    .value("Keep the screen on", { Self.cycleLabel("screen_on", [0, 2, 1], ["No", "While playing", "Always"]) },
                           { [weak self] in self?.cycle("screen_on", [0, 2, 1]) }),
                    .info("Screen turns off after", "Set Auto-Lock in iPhone Settings → Display & Brightness"),
                ]),
                ("Night light and clock", [
                    .toggle("Night light", "A warm glow all through bedtime, instead of a black screen. Keep it on the charger", "night_light"),
                    .toggle("OK to wake", "The night light turns green when bedtime ends", "ok_to_wake"),
                    .toggle("Clock on the night light", nil, "night_clock"),
                    .toggle("Clock and battery", nil, "show_status"),
                ]),
            ]
        case "safety":
            sections = [
                (nil, [
                    .toggle("Grown-up check before settings", Store.gatePin().isEmpty ? "A quick sum" : "The grown-up PIN", "gate"),
                    .value("Grown-up PIN", { Store.gatePin().isEmpty ? "Not set" : "Set" }, { [weak self] in self?.editGatePin() }),
                    .info("Lock to this app", UIAccessibility.isGuidedAccessEnabled ? "On (Guided Access)" : "Triple-click the Home button to start Guided Access"),
                ]),
                ("Phone", [.value("iPhone settings", { "Wi-Fi, Bluetooth, brightness" }, { Self.openSettings(nil) })]),
            ]
        case "remote":
            sections = [
                (nil, [.toggle("Remote control", nil, "remote")]),
                ("Connect", [
                    .info("Address", RemoteServer.address ?? "Not on Wi-Fi"),
                    .info("PIN", RemoteServer.pin),
                    .value("Change PIN", { "" }, { [weak self] in
                        self?.confirm("Make a new PIN?", "Remote controls will need the new PIN.") { RemoteServer.newPin(); self?.reload() }
                    }),
                ]),
            ]
        case "about":
            sections = [
                (nil, [.info("WalkieTales " + Self.version + " for iPhone", Self.freeSpace())]),
                ("Updates", [.info("New versions", "Install them with TrollStore. Android players update from the remote.")]),
            ]
        default: buildMenu()
        }
    }

    private func buildMenu() {
        sections = [
            (nil, [.menu("person.fill", "Your child", { let n = Store.string("kid_name"); return n.isEmpty ? "Not set" : n }, "@name")]),
            (nil, [
                .menu("square.grid.3x3.fill", "Library", { let n = Store.folders().count; return "\(n) " + (n == 1 ? "folder" : "folders") }, "library"),
                .menu("creditcard.fill", "Cards", { "Not on iPhone yet" }, "cards"),
            ]),
            (nil, [
                .menu("speaker.wave.2.fill", "Sound", { "Maximum volume \(Store.int("max_volume"))%" }, "sound"),
                .menu("moon.fill", "Bedtime", { Self.time(Store.int("quiet_start")) + " to " + Self.time(Store.int("quiet_end")) }, "bedtime"),
                .menu("iphone", "Screen", { Self.screenSummary() }, "screen"),
            ]),
            (nil, [
                .menu("shield.fill", "Safety", { !Store.bool("gate") ? "Grown-up check off" : Store.gatePin().isEmpty ? "Grown-up sum on" : "Grown-up PIN on" }, "safety"),
                .menu("wifi", "Remote control", { Store.bool("remote") ? "On" : "Off" }, "remote"),
                .menu("info.circle.fill", "About", { "WalkieTales " + Self.version }, "about"),
            ]),
        ]
    }

    private func buildLibrary() {
        let folders = Store.folders()
        var lib: [Row] = folders.map { f in .value(f, { Self.folderSummary(f) }, { [weak self] in self?.folderOptions(f) }) }
        if folders.isEmpty { lib.append(.info("No folders yet", "Add music from the remote, or with the Files app (On My iPhone → WalkieTales → Cards)")) }
        lib.append(.value("Shuffle everything", { "" }, { [weak self] in self?.playNow(Store.ALL) }))
        sections = [
            ("Folders", lib),
            ("Covers", [.toggle("Find missing covers online", nil, "find_art")]),
            ("On the player", [.toggle("Library button", nil, "browse"), .toggle("Tracks button", nil, "track_list")]),
        ]
    }

    private func buildSound() {
        sections = [
            (nil, [.slider("Maximum volume", "max_volume")]),
            (nil, [.toggle("Volume buttons on screen", nil, "show_volume"), .toggle("Fade in", nil, "fade_in")]),
            ("Headphones", [
                .toggle("Headphones button", "Picks headphones or the speaker from the player", "headphones_button"),
                .value("Pair new headphones", { "iPhone Settings → Bluetooth" }, { Self.openSettings("Bluetooth") }),
                .info("Pairing needs Guided Access off", "Triple-click the Home button to leave it, pair in Settings, then start Guided Access again."),
            ]),
        ]
    }

    private func reload() { build(); tableView.reloadData() }

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
