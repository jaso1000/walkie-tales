import UIKit

/// Grown-up settings (behind the cog and the quick sum). Same settings as the Android player.
final class SettingsViewController: UITableViewController {
    weak var owner: PlayerViewController?

    enum Row {
        case toggle(String, String?, String)                 // title, subtitle, key
        case value(String, () -> String, () -> Void)        // title, current value, tap
        case slider(String, String)                          // title, key (10–100 %)
        case info(String, String?)
    }

    private var sections: [(String, [Row])] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Grown-up settings"
        overrideUserInterfaceStyle = .dark
        navigationController?.overrideUserInterfaceStyle = .dark
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        build()
    }

    @objc private func done() {
        dismiss(animated: true) { self.owner?.applySettings(); self.owner?.wake() }
    }

    private func build() {
        let folders = Store.folders()
        var lib: [Row] = folders.map { f in .value(f, { Self.folderSummary(f) }, { [weak self] in self?.folderOptions(f) }) }
        if folders.isEmpty { lib.append(.info("No folders yet", "Add music from the remote, or with the Files app (On My iPhone → WalkieTales → Cards)")) }
        lib.append(.value("Shuffle everything", { "" }, { [weak self] in self?.playNow(Store.ALL) }))
        lib.append(.toggle("Find missing covers online", nil, "find_art"))

        sections = [
            ("Your child", [.value("Name", { let n = Store.string("kid_name"); return n.isEmpty ? "Not set" : n }, { [weak self] in self?.editName() })]),
            ("Library", lib),
            ("Sound", [
                .slider("Maximum volume", "max_volume"),
                .toggle("Volume buttons on screen", nil, "show_volume"),
                .toggle("Fade in", nil, "fade_in"),
            ]),
            ("Bedtime", [
                .value("Bedtime starts", { Self.time(Store.int("quiet_start")) }, { [weak self] in self?.pickTime("quiet_start") }),
                .value("Bedtime ends", { Self.time(Store.int("quiet_end")) }, { [weak self] in self?.pickTime("quiet_end") }),
                .toggle("Screen off at bedtime", "Goes black 30 seconds after the last touch", "bedtime_dark"),
                .toggle("Quieter at bedtime", nil, "quiet"),
                .slider("Bedtime maximum volume", "quiet_volume"),
            ]),
            ("Browsing", [.toggle("Library button", nil, "browse"), .toggle("Tracks button", nil, "track_list")]),
            ("Screen", [
                .value("Dim the screen after", { Self.cycleLabel("dim_after", [30, 90, 300, 0], ["30 seconds", "90 seconds", "5 minutes", "Never"]) },
                       { [weak self] in self?.cycle("dim_after", [30, 90, 300, 0]) }),
                .value("Keep the screen on", { Self.cycleLabel("screen_on", [0, 2, 1], ["No", "While playing", "Always"]) },
                       { [weak self] in self?.cycle("screen_on", [0, 2, 1]) }),
                .info("Screen turns off after", "Set Auto-Lock in iPhone Settings → Display & Brightness"),
                .toggle("Night light", nil, "night_light"),
                .toggle("Clock on the night light", nil, "night_clock"),
                .toggle("Clock and battery", nil, "show_status"),
            ]),
            ("Safety", [
                .toggle("Grown-up sum before settings", nil, "gate"),
                .info("Lock to this app", UIAccessibility.isGuidedAccessEnabled ? "On (Guided Access)" : "Triple-click the Home button to start Guided Access"),
                .value("iPhone settings", { "Wi-Fi, Bluetooth, brightness" }, { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }),
            ]),
            ("Remote control", [
                .toggle("Remote control", nil, "remote"),
                .info(RemoteServer.address ?? "Not on Wi-Fi", "PIN: " + RemoteServer.pin),
                .value("Change PIN", { "" }, { [weak self] in self?.confirm("Make a new PIN?", "Remote controls will need the new PIN.") { RemoteServer.newPin(); self?.reload() } }),
            ]),
            ("About", [.info("WalkieTales " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""), Self.freeSpace())]),
        ]
    }

    private func reload() { build(); tableView.reloadData() }

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
            cell.textLabel?.text = title + "  \(Store.int(key))%"
            let sl = UISlider(frame: CGRect(x: 0, y: 0, width: 150, height: 30))
            sl.minimumValue = 10
            sl.maximumValue = 100
            sl.value = Float(Store.int(key))
            sl.addAction(UIAction { _ in
                let v = Int((sl.value / 5).rounded()) * 5
                Store.set(key, v)
                cell.textLabel?.text = title + "  \(v)%"
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
        if case let .value(_, _, tap) = sections[ip.section].1[ip.row] { tap() }
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
        dismiss(animated: true) { Player.shared.open(f, play: true); self.owner?.applySettings() }
    }

    private func confirm(_ title: String, _ msg: String, _ yes: @escaping () -> Void) {
        let a = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Yes", style: .default) { _ in yes() })
        present(a, animated: true)
    }

    // MARK: helpers

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
