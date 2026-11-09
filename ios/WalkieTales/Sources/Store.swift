import AVFoundation
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

    /// The grown-up PIN asked for instead of the sum before settings: 4 to 8 digits, or none.
    static func gatePin() -> String {
        let s = ud.string(forKey: "gate_pin") ?? ""
        return s.range(of: "^[0-9]{4,8}$", options: .regularExpression) != nil ? s : ""
    }

    static func settingsJson() -> [String: Any] {
        var o: [String: Any] = ["gate_pin_set": !gatePin().isEmpty] // the PIN itself never leaves the phone
        for (k, d) in defaults {
            if d is Bool { o[k] = bool(k) } else if d is Int { o[k] = int(k) } else { o[k] = string(k) }
        }
        return o
    }

    /// Apply known keys from the remote, coercing types and clamping ranges like Android does.
    static func applySettings(_ inp: [String: Any]) {
        if let v = inp["gate_pin"] { // set from the remote (e.g. a forgotten PIN): 4-8 digits, or "" to go back to the sum
            let pin = "\(v)".trimmingCharacters(in: .whitespaces)
            if pin.isEmpty { ud.removeObject(forKey: "gate_pin") }
            else if pin.range(of: "^[0-9]{4,8}$", options: .regularExpression) != nil { ud.set(pin, forKey: "gate_pin") }
        }
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
    /// What an audio file really holds, from its first bytes (audiobook tools often save AAC/M4A under an .mp3 name).
    /// "m4a", "aac", "mp3", "flac", "wav", "ogg", or nil when it can't tell.
    static func audioKind(_ u: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: u) else { return nil }
        defer { try? h.close() }
        var d = h.readData(ofLength: 16)
        var skip = 0
        if d.count >= 10, d[0] == 0x49, d[1] == 0x44, d[2] == 0x33 { // "ID3" tag first: look past it
            skip = 10 + (Int(d[6] & 0x7f) << 21 | Int(d[7] & 0x7f) << 14 | Int(d[8] & 0x7f) << 7 | Int(d[9] & 0x7f))
            try? h.seek(toOffset: UInt64(skip))
            d = h.readData(ofLength: 16)
        }
        guard d.count >= 12 else { return nil }
        if d[4] == 0x66, d[5] == 0x74, d[6] == 0x79, d[7] == 0x70 { return "m4a" }          // ....ftyp
        if d[0] == 0x66, d[1] == 0x4C, d[2] == 0x61, d[3] == 0x43 { return "flac" }        // fLaC
        if d[0] == 0x52, d[1] == 0x49, d[2] == 0x46, d[3] == 0x46 { return "wav" }         // RIFF
        if d[0] == 0x4F, d[1] == 0x67, d[2] == 0x67, d[3] == 0x53 { return "ogg" }         // OggS
        if d[0] == 0xFF, (d[1] & 0xF6) == 0xF0 { return "aac" }                            // ADTS AAC (layer bits 00)
        if d[0] == 0xFF, (d[1] & 0xE0) == 0xE0 { return "mp3" }                            // MPEG audio frame
        return nil
    }

    /// A URL AVFoundation will decode properly: if the name says one thing and the bytes another, play it
    /// through a link with the right extension (the file itself isn't touched).
    static func playableURL(_ u: URL) -> URL {
        guard let kind = audioKind(u) else { return u }
        let ext = u.pathExtension.lowercased()
        let same = kind == ext || (kind == "m4a" && ["m4a", "m4b", "mp4", "aac", "alac"].contains(ext)) || (kind == "aac" && ext == "aac")
        if same { return u }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relabelled", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("\(abs(u.path.hashValue)).\(kind)")
        try? FileManager.default.removeItem(at: link)
        do { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: u) } catch { return u }
        return link
    }

    static func listTracks(_ folder: String) -> [Track] {
        let st = stamp(folder)
        trackLock.lock()
        if let c = trackCache[folder], c.stamp == st { trackLock.unlock(); return c.tracks }
        trackLock.unlock()
        let t = readTracks(folder)
        trackLock.lock(); trackCache[folder] = (st, t); trackLock.unlock()
        return t
    }

    // MARK: categories (Library: All, Music, Podcasts, Audiobooks, Radio) — same rules as Android's Store.detectCategory

    static let categories = ["music", "podcast", "audiobook", "radio"]
    private static var catCache: [String: (stamp: Double, cat: String)] = [:]
    private static let catLock = NSLock()

    /// The grown-up's choice from the remote, or the guess.
    static func category(_ folder: String) -> String {
        if let c = ud.string(forKey: "cat:" + folder), categories.contains(c) { return c }
        return autoCategory(folder)
    }

    static func setCategory(_ folder: String, _ c: String?) {
        if let c = c { ud.set(c, forKey: "cat:" + folder) } else { ud.removeObject(forKey: "cat:" + folder) }
    }

    /// What the folder looks like, remembered until it changes: genre tags ("Podcast", "Audiobook", "Spoken Word"),
    /// .m4b files and words in the names.
    static func autoCategory(_ folder: String) -> String {
        let st = stamp(folder)
        catLock.lock()
        if let c = catCache[folder], c.stamp == st { catLock.unlock(); return c.cat }
        catLock.unlock()
        let saved = ud.string(forKey: "autocat:" + folder)?.split(separator: "|").map(String.init)
        if let s = saved, s.count == 2, Double(s[0]) == st { catLock.lock(); catCache[folder] = (st, s[1]); catLock.unlock(); return s[1] }
        let cat = detectCategory(folder)
        ud.set("\(st)|\(cat)", forKey: "autocat:" + folder)
        catLock.lock(); catCache[folder] = (st, cat); catLock.unlock()
        return cat
    }

    private static func detectCategory(_ folder: String) -> String {
        let tracks = listTracks(folder)
        if !tracks.isEmpty && tracks.allSatisfy({ $0.live }) { return "radio" }
        let files = tracks.filter { !$0.live }.map { $0.source }
        var genres = ""
        for u in files.prefix(3) {
            let meta = AVURLAsset(url: u).metadata
            let ids: [AVMetadataIdentifier] = [.id3MetadataContentType, .iTunesMetadataUserGenre, .quickTimeMetadataGenre]
            for id in ids { for item in AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: id) { genres += (item.stringValue ?? "") + " " } }
        }
        let g = genres.lowercased()
        let names = ([folder] + files.prefix(5).map { $0.lastPathComponent }).joined(separator: " ")
        func has(_ pattern: String) -> Bool { names.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        if g.contains("podcast") || has("podcast|\\bepisode\\b|\\bep\\.? ?\\d") { return "podcast" }
        if files.contains(where: { $0.pathExtension.lowercased() == "m4b" }) || g.contains("audiobook") || g.contains("audio book")
            || g.contains("spoken") || g.contains("speech") || g.contains("story")
            || has("audio ?book|\\bstor(y|ies)\\b|\\bchapter\\b|\\bnarrated\\b|\\bread by\\b|\\bunabridged\\b|\\btales\\b") { return "audiobook" }
        return "music"
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
