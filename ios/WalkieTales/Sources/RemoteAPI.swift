import UIKit

/// The remote-control API (same endpoints and JSON as the Android player, so the companion page works as is).
extension PlayerViewController {

    func remote(_ r: RemoteServer.Request, _ b: [String: Any]) throws -> [String: Any]? {
        let post = r.method == "POST"
        switch r.path {
        case "/api/status": return statusJson()
        case "/api/library": return library()
        case "/api/cards": return ["cards": [], "linking": NSNull()]
        case "/api/settings":
            if post { Store.applySettings(b); applySettings() }
            return ["settings": Store.settingsJson()]
        default: break
        }
        guard post else { return nil }
        if !screenLocked { wake() }
        switch r.path {
        case "/api/play":
            let f = b["folder"] as? String ?? ""
            guard f == Store.ALL || (Store.safeName(f) != nil && Store.folders().contains(f)) else { throw RemoteError("No folder called \(f)") }
            p.open(f, play: true)
        case "/api/toggle": p.toggle()
        case "/api/pause": p.pause()
        case "/api/resume": if !p.isPlaying { p.toggle() }
        case "/api/next": p.next()
        case "/api/prev": p.prev()
        case "/api/restart": p.restart()
        case "/api/stop": p.stop()
        case "/api/track":
            let i = (b["index"] as? NSNumber)?.intValue ?? -1
            guard p.tracks.indices.contains(i) else { throw RemoteError("No such track") }
            p.start(i, play: true)
        case "/api/seek":
            p.seek(((b["ms"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        case "/api/volume":
            if let l = (b["level"] as? NSNumber)?.intValue { Volume.shared.set(level: l) }
            else { _ = Volume.shared.change((b["delta"] as? NSNumber)?.intValue ?? 0) }
            renderVolume()
        case "/api/sleep":
            p.setSleep(minutes: (b["minutes"] as? NSNumber)?.intValue ?? 0)
        case "/api/find": // "Ring the player" on the remote's Playing tab
            if (b["on"] as? Bool) ?? true { Finder.shared.start(self) } else { Finder.shared.stop() }
        case "/api/screen":
            setScreenLocked((b["off"] as? Bool) ?? !screenLocked)
        case "/api/message":
            let t = String((b["text"] as? String ?? "").trimmingCharacters(in: .whitespaces).prefix(120))
            if !t.isEmpty { flash(t, 20) }
        case "/api/covers/find":
            findCovers(force: (b["force"] as? Bool) ?? true)
            return ["started": true]
        case "/api/covers/remove":
            guard let f = Store.safeName(b["folder"] as? String) else { throw RemoteError("Bad folder") }
            ArtFinder.reject(f)
            if p.folder == f { applyTheme(); lastIndex = -1; updateUi() }
        case "/api/folder/delete": // remote → Library → "Delete": remove a folder and everything in it
            let f = b["folder"] as? String ?? ""
            guard Store.safeName(f) != nil, Store.folders().contains(f) else { throw RemoteError("No folder called \(f)") }
            if p.folder == f { p.stop() }
            do { try FileManager.default.removeItem(at: Store.dir(f)) } catch { throw RemoteError("Couldn't delete \(f)") }
            flash("Deleted “\(f)”", 3)
            libraryChanged()
        case "/api/station":
            let name = String((b["name"] as? String ?? "").trimmingCharacters(in: .whitespaces).prefix(60))
            let url = (b["url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let fold = (b["folder"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw RemoteError("Give the station a name") }
            guard Store.isUrl(url), url.count <= 1000 else { throw RemoteError("The stream address must start with http:// or https://") }
            guard let dir = Store.safeName(fold.isEmpty ? name.replacingOccurrences(of: "/", with: "") : fold) else { throw RemoteError("Bad folder name") }
            try Store.addStation(folder: dir, name: name, url: url)
            findCovers(force: false)
            flash("New radio station: \(name)", 4)
            (presentedViewController as? LibraryViewController)?.reload()
        case "/api/ui": // used by the automated simulator test to open screens for screenshots
            if let bat = b["battery"] as? String { BatteryView.testOverride = bat; batteryChanged(); return statusJson() }
            let show = b["show"] as? String ?? ""
            presentedViewController?.dismiss(animated: false)
            switch show {
            case "library": openLibrary()
            case "tracks": openTracks()
            case let s where s.hasPrefix("settings"): // "settings", or "settings-sound" etc. for one page
                let menu = SettingsViewController(page: nil)
                menu.owner = self
                let nav = UINavigationController(rootViewController: menu)
                nav.modalPresentationStyle = .fullScreen
                present(nav, animated: false)
                if s.hasPrefix("settings-") {
                    let pg = SettingsViewController(page: String(s.dropFirst(9)))
                    pg.owner = self
                    nav.pushViewController(pg, animated: false)
                }
            default: break
            }
        case "/api/cards/link", "/api/cards/cancel", "/api/cards/unlink":
            throw RemoteError("Cards aren't available on the iPhone player yet")
        default: return nil
        }
        return statusJson()
    }

    func statusJson() -> [String: Any] {
        var s: [String: Any] = [:]
        s["version"] = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") + " (iOS)"
        s["name"] = Store.string("kid_name")
        s["bluetooth"] = HeadphonesButton.bluetooth
        s["headphones"] = HeadphonesButton.output() ?? NSNull()
        s["finding"] = Finder.shared.ringing
        let have = p.folder != nil && !p.tracks.isEmpty
        s["folder"] = have ? p.folder! : NSNull()
        s["title"] = have ? Store.label(p.folder!) : NSNull()
        s["playing"] = p.isPlaying
        if have, let t = p.current {
            s["track"] = t.name
            s["trackIndex"] = p.index
            s["trackCount"] = p.tracks.count
            s["tracks"] = p.tracks.map { $0.name }
        }
        s["live"] = p.isLive
        s["connecting"] = p.connecting
        if p.player != nil && !p.isLive {
            s["position"] = Int(p.position * 1000)
            s["duration"] = Int(p.duration * 1000)
        }
        let v = Volume.shared
        s["volume"] = ["level": v.level, "cap": v.capSteps, "max": v.steps, "quiet": v.quietNow]
        s["sleepMinutesLeft"] = p.sleepAt.map { Int(($0.timeIntervalSinceNow + 59) / 60) } ?? 0
        let d = UIDevice.current
        s["battery"] = d.batteryLevel < 0 ? -1 : Int((d.batteryLevel * 100).rounded())
        s["charging"] = d.batteryState == .charging || d.batteryState == .full
        s["linking"] = NSNull()
        s["accent"] = Art.hex(accent)
        s["message"] = status.text ?? ""
        s["locked"] = UIAccessibility.isGuidedAccessEnabled
        s["nfc"] = "not on iPhone yet"
        s["screenOff"] = screenLocked
        s["bedtime"] = Bedtime.now
        s["dark"] = !blackout.isHidden
        return s
    }

    func library() -> [String: Any] {
        var arr: [[String: Any]] = []
        for f in Store.folders() {
            let tracks = Store.listTracks(f)
            arr.append([
                "name": f, "tracks": tracks.count, "live": Store.isLiveOnly(f), "autoCover": Art.hasAuto(f), "cards": 0,
                "info": LibraryViewController.info(f, player: p), "color": Art.hex(Art.colorFor(f)),
                "shuffle": Store.flag("shuffle", f, false), "repeat": Store.flag("repeat", f, false),
            ])
        }
        var free: Int64 = 0
        if let v = try? Store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let c = v.volumeAvailableCapacityForImportantUsage { free = c }
        return ["folders": arr, "actions": [] as [Any], "freeBytes": free]
    }
}
