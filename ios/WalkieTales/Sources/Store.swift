import Foundation
import UIKit

/// A music file or a live radio stream.
struct Track: Equatable {
    let source: URL      // file URL, or http(s) stream URL
    let name: String
    let live: Bool
}

/// Library, settings and saved positions. Mirrors the Android app's Store so the remote page works unchanged.
///
/// Music lives in the app's Documents/Cards/<folder>/ (visible in the Files app and uploadable from the remote).
enum Store {
    static let ALL = "@all"

    static let audioExt: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "caf", "flac", "alac", "mp4"]
    static let playlistExt: Set<String> = ["m3u", "m3u8", "pls", "url"]
    static let imageExt: Set<String> = ["jpg", "jpeg", "png", "webp", "heic"]

    // MARK: settings (same keys and defaults as Android)

    static let defaults: [(String, Any)] = [
        ("kid_name", ""), ("max_volume", 70), ("show_volume", true), ("headphones_button", true), ("fade_in", true), ("announce", false),
        ("quiet", false), ("quiet_start", 19 * 60), ("quiet_end", 7 * 60), ("quiet_volume", 40), ("bedtime_dark", false),
        ("cards", false), ("find_art", true), ("browse", true), ("track_list", true), ("rest_mode", false), ("cards_awake", true),
        ("dim_after", 90), ("screen_on", 0), ("screen_timeout", 60), ("night_light", false), ("night_clock", true),
        ("show_status", true), ("gate", true), ("power_menu", true), ("remote", true),
    ]

    static let ud = UserDefaults.standard

    static func bool(_ k: String) -> Bool {
        if ud.object(forKey: k) == nil, let d = defaults.first(where: { $0.0 == k })?.1 as? Bool { return d }
        return ud.bool(forKey: k)
    }

    static func int(_ k: String) -> Int {
        if ud.object(forKey: k) == nil, let d = defaults.first(where: { $0.0 == k })?.1 as? Int { return d }
        return ud.integer(forKey: k)
    }

    static func string(_ k: String) -> String {
        ud.string(forKey: k) ?? (defaults.first(where: { $0.0 == k })?.1 as? String ?? "")
    }

    static func set(_ k: String, _ v: Any?) { ud.set(v, forKey: k) }

    static func settingsJson() -> [String: Any] {
        var o: [String: Any] = [:]
        for (k, d) in defaults {
            if d is Bool { o[k] = bool(k) } else if d is Int { o[k] = int(k) } else { o[k] = string(k) }
        }
        return o
    }

    /// Apply known keys from the remote, coercing types and clamping ranges like Android does.
    static func applySettings(_ inp: [String: Any]) {
        for (k, d) in defaults {
            guard let v = inp[k] else { continue }
            if d is Bool {
                set(k, (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? false))
            } else if d is Int {
                var n = (v as? Int) ?? (v as? NSNumber)?.intValue ?? Int("\(v)") ?? (d as! Int)
                switch k {
                case "max_volume", "quiet_volume": n = max(10, min(100, n))
                case "quiet_start", "quiet_end": n = max(0, min(24 * 60 - 1, n))
                case "dim_after": n = max(0, min(3600, n))
                case "screen_on": n = (n == 1 || n == 2) ? n : 0
                case "screen_timeout": n = max(15, min(1800, n))
                default: break
                }
                set(k, n)
            } else {
                let s = "\(v)".trimmingCharacters(in: .whitespacesAndNewlines)
                set(k, String(s.prefix(40)))
            }
        }
    }

    // MARK: library

    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let r = docs.appendingPathComponent("Cards", isDirectory: true)
        if !FileManager.default.fileExists(atPath: r.path) {
            try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        }
        return r
    }

    static func folders() -> [String] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .sorted { natLess($0, $1) }
    }

    /// The name without emoji and other pictographs, with spaces tidied up.
    static func plainName(_ s: String) -> String {
        let kept = s.unicodeScalars.filter { !($0.properties.isEmoji && $0.value > 0xFF) && $0.value != 0xFE0F && $0.value != 0x200D }
        return String(String.UnicodeScalarView(kept)).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    static func dir(_ folder: String) -> URL { root.appendingPathComponent(folder, isDirectory: true) }

    /// Audio files in a folder (including subfolders), naturally sorted by path.
    static func listAudio(_ d: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: d, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let u as URL in e where audioExt.contains(u.pathExtension.lowercased()) { out.append(u) }
        let base = d.path
        return out.sorted { natLess(String($0.path.dropFirst(base.count)), String($1.path.dropFirst(base.count))) }
    }

    // MARK: remembered folders (like Android's Store.FolderInfo)

    private static var trackCache: [String: (stamp: Double, tracks: [Track])] = [:]
    private static let trackLock = NSLock()

    /// Changes whenever a file is added, removed or renamed in the folder (or its sub-folders), or a playlist is edited.
    static func stamp(_ folder: String) -> Double {
        let d = dir(folder)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        var s = (try? d.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let items = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        for u in items {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true || playlistExt.contains(u.pathExtension.lowercased()) {
                s = max(s, v.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
        }
        return s
    }

    /// Everything playable in a folder, re-read only when the folder changed.
    static func listTracks(_ folder: String) -> [Track] {
        let st = stamp(folder)
        trackLock.lock()
        if let c = trackCache[folder], c.stamp == st { trackLock.unlock(); return c.tracks }
        trackLock.unlock()
        let t = readTracks(folder)
        trackLock.lock(); trackCache[folder] = (st, t); trackLock.unlock()
        return t
    }

    private static func readTracks(_ folder: String) -> [Track] {
        let d = dir(folder)
        var out = listAudio(d).map { Track(source: $0, name: cleanName($0), live: false) }
        out += listStreams(d)
        return out
    }

    static func isLiveOnly(_ folder: String) -> Bool {
        let t = listTracks(folder)
        return !t.isEmpty && t.allSatisfy { $0.live }
    }

    static func listStreams(_ d: URL) -> [Track] {
        let items = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var out: [Track] = []
        for u in items.sorted(by: { natLess($0.lastPathComponent, $1.lastPathComponent) })
        where playlistExt.contains(u.pathExtension.lowercased()) {
            for (name, url) in parsePlaylist(u) { out.append(Track(source: url, name: name, live: true)) }
        }
        return out
    }

    /// .m3u/.m3u8 (#EXTINF titles), .pls (FileN/TitleN), .url (URL=) → (name, stream URL)
    static func parsePlaylist(_ f: URL) -> [(String, URL)] {
        guard let text = (try? String(contentsOf: f, encoding: .utf8)) ?? (try? String(contentsOf: f, encoding: .isoLatin1)) else { return [] }
        let fallback = f.deletingPathExtension().lastPathComponent
        var out: [(String, URL)] = []
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        switch f.pathExtension.lowercased() {
        case "pls":
            var files: [Int: String] = [:], titles: [Int: String] = [:]
            for l in lines {
                let lower = l.lowercased()
                if lower.hasPrefix("file"), let eq = l.firstIndex(of: "="), let n = Int(l[l.index(l.startIndex, offsetBy: 4)..<eq]) {
                    files[n] = String(l[l.index(after: eq)...])
                } else if lower.hasPrefix("title"), let eq = l.firstIndex(of: "="), let n = Int(l[l.index(l.startIndex, offsetBy: 5)..<eq]) {
                    titles[n] = String(l[l.index(after: eq)...])
                }
            }
            for n in files.keys.sorted() {
                if let s = files[n], let u = URL(string: s), isUrl(s) { out.append((titles[n] ?? fallback, u)) }
            }
        case "url":
            for l in lines where l.lowercased().hasPrefix("url=") {
                let s = String(l.dropFirst(4))
                if isUrl(s), let u = URL(string: s) { out.append((fallback, u)) }
            }
        default:
            var title: String?
            for l in lines {
                if l.uppercased().hasPrefix("#EXTINF") {
                    if let c = l.firstIndex(of: ",") { title = String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces) }
                } else if !l.isEmpty && !l.hasPrefix("#") {
                    if isUrl(l), let u = URL(string: l) { out.append((title?.isEmpty == false ? title! : fallback, u)) }
                    title = nil
                }
            }
        }
        return out.map { ($0.0, rewriteStream($0.1)) }
    }

    /// StreamTheWorld numbered servers rotate: use their official redirect instead (same as Android).
    static func rewriteStream(_ u: URL) -> URL {
        guard let h = u.host, h.hasSuffix(".live.streamtheworld.com"), h.first?.isNumber == true else { return u }
        let mount = u.lastPathComponent
        return URL(string: "https://playerservices.streamtheworld.com/api/livestream-redirect/" + mount) ?? u
    }

    static func isUrl(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.hasPrefix("http://") || l.hasPrefix("https://")
    }

    static func addStation(folder: String, name: String, url: String) throws {
        let d = dir(folder)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let body = "#EXTM3U\n#EXTINF:-1,\(name)\n\(url)\n"
        try body.write(to: d.appendingPathComponent(safe + ".m3u"), atomically: true, encoding: .utf8)
    }

    /// "01 - Song_Name.mp3" → "Song Name"
    static func cleanName(_ u: URL) -> String {
        var n = u.deletingPathExtension().lastPathComponent
        if let r = n.range(of: "^\\d+[\\s._-]*", options: .regularExpression) {
            let stripped = String(n[r.upperBound...])
            if !stripped.isEmpty { n = stripped }
        }
        return n.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func natLess(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }

    static func label(_ target: String) -> String { target == ALL ? "Everything" : target }

    /// Folder or file name sent by the remote: no paths, no hidden files.
    static func safeName(_ s: String?) -> String? {
        guard let n = s?.trimmingCharacters(in: .whitespaces), !n.isEmpty, !n.hasPrefix("."),
              !n.contains("/"), !n.contains("\\"), n.count <= 200 else { return nil }
        return n
    }

    // MARK: positions

    static func savePosition(_ folder: String, index: Int, ms: Int) { set("pos:" + folder, "\(index):\(ms)") }

    static func position(_ folder: String) -> (Int, Int) {
        let p = (ud.string(forKey: "pos:" + folder) ?? "0:0").split(separator: ":")
        return (Int(p.first ?? "0") ?? 0, Int(p.count > 1 ? p[1] : "0") ?? 0)
    }

    static func flag(_ key: String, _ folder: String, _ def: Bool) -> Bool {
        let k = key + ":" + folder
        return ud.object(forKey: k) == nil ? def : ud.bool(forKey: k)
    }
}
