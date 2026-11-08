import AVFoundation
import UIKit

/// Covers, colours and letter tiles (same rules as Android's Ui + ArtFinder).
enum Art {
    static let coverNames = ["cover", "folder", "front", "album"]
    static let autoCover = "cover.auto.jpg"

    /// Named cover > any image > picture inside the first track > cover found online.
    static func folderCover(_ folder: String, max: CGFloat = 900) -> UIImage? {
        let d = Store.dir(folder)
        let items = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var any: URL?, auto: URL?
        for u in items where Store.imageExt.contains(u.pathExtension.lowercased()) {
            let n = u.lastPathComponent.lowercased()
            if n == autoCover { auto = u; continue }
            if coverNames.contains(u.deletingPathExtension().lastPathComponent.lowercased()) { return load(u, max: max) }
            if any == nil { any = u }
        }
        if let a = any { return load(a, max: max) }
        if let first = Store.listAudio(d).first, let e = embedded(first) { return scaled(e, max: max) }
        if let a = auto { return load(a, max: max) }
        return nil
    }

    private static let tiles: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.totalCostLimit = 40 * 1024 * 1024; return c }()
    private static let noCover = UIImage()

    /// A Library tile's cover, small and remembered until the folder changes (like Android's Ui.tile).
    static func tile(_ folder: String) -> UIImage? {
        let key = "\(folder)|\(Store.stamp(folder))" as NSString
        if let t = tiles.object(forKey: key) { return t === noCover ? nil : t }
        let img = folderCover(folder, max: 400)
        let cost = img.map { Int($0.size.width * $0.size.height * $0.scale * $0.scale * 4) } ?? 1
        tiles.setObject(img ?? noCover, forKey: key, cost: cost)
        return img
    }

    /// Only what's already remembered, so the Library can show it straight away.
    static func cachedTile(_ folder: String) -> UIImage? {
        let t = tiles.object(forKey: "\(folder)|\(Store.stamp(folder))" as NSString)
        return t === noCover ? nil : t
    }

    static func hasPicture(_ folder: String) -> Bool {
        let d = Store.dir(folder)
        let items = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
        if items.contains(where: { Store.imageExt.contains($0.pathExtension.lowercased()) }) { return true }
        if let first = Store.listAudio(d).first { return embedded(first) != nil }
        return false
    }

    static func hasAuto(_ folder: String) -> Bool {
        FileManager.default.fileExists(atPath: Store.dir(folder).appendingPathComponent(autoCover).path)
    }

    static func load(_ u: URL, max: CGFloat = 900) -> UIImage? {
        guard let img = UIImage(contentsOfFile: u.path) else { return nil }
        return scaled(img, max: max)
    }

    /// The picture built into a music file (ID3 APIC, MP4 covr, FLAC picture…).
    static func embeddedData(_ u: URL) -> Data? {
        let asset = AVURLAsset(url: u)
        for item in asset.commonMetadata where item.commonKey == .commonKeyArtwork {
            if let d = item.dataValue { return d }
            if let d = item.value as? Data { return d }
        }
        for fmt in asset.availableMetadataFormats {
            for item in asset.metadata(forFormat: fmt) where item.commonKey == .commonKeyArtwork {
                if let d = item.dataValue { return d }
            }
        }
        return nil
    }

    static func embedded(_ u: URL) -> UIImage? {
        guard let d = embeddedData(u), let img = UIImage(data: d) else { return nil }
        return scaled(img, max: 900)
    }

    static func scaled(_ img: UIImage, max: CGFloat) -> UIImage {
        let s = img.size
        let k = min(1, max / Swift.max(s.width, s.height))
        if k >= 1 { return img }
        let size = CGSize(width: s.width * k, height: s.height * k)
        return UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }

    // MARK: colours

    static func colorFor(_ name: String) -> UIColor {
        var h: Int32 = 0
        for c in name.lowercased().utf16 { h = 31 &* h &+ Int32(truncatingIfNeeded: Int(c)) } // like Java's hashCode
        let hue = CGFloat(((Int(h) % 360) + 360) % 360) / 360
        return UIColor(hue: hue, saturation: 0.6, brightness: 0.85, alpha: 1)
    }

    /// A lively average colour of the picture, so the screen follows the cover art.
    static func dominant(_ img: UIImage, fallback: UIColor) -> UIColor {
        guard let cg = img.cgImage else { return fallback }
        let w = 24, h = 24
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return fallback }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var best: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, -1)
        var buckets: [Int: (Int, Int, Int, Int)] = [:]
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            let mx = max(r, g, b), mn = min(r, g, b)
            if mx < 40 || mx - mn < 30 { continue } // skip near-black and greys
            let key = (r / 43) * 36 + (g / 43) * 6 + b / 43
            let e = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (e.0 + r, e.1 + g, e.2 + b, e.3 + 1)
        }
        for (_, v) in buckets where CGFloat(v.3) > best.3 {
            best = (CGFloat(v.0) / CGFloat(v.3), CGFloat(v.1) / CGFloat(v.3), CGFloat(v.2) / CGFloat(v.3), CGFloat(v.3))
        }
        if best.3 < 3 { return fallback }
        return UIColor(red: best.0 / 255, green: best.1 / 255, blue: best.2 / 255, alpha: 1)
    }

    static func shade(_ c: UIColor, _ amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        let k = 1 - amount
        return UIColor(red: r * k, green: g * k, blue: b * k, alpha: 1)
    }

    static func tint(_ c: UIColor, _ amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r + (1 - r) * amount, green: g + (1 - g) * amount, blue: b + (1 - b) * amount, alpha: 1)
    }

    /// "#RRGGBB" -> colour.
    static func color(_ hex: String) -> UIColor {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0x6C4CF1
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ c: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// A big letter on a gradient, for folders without a picture.
    static func letter(_ s: String, _ c: UIColor) -> UIImage {
        let size = CGSize(width: 600, height: 600)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [tint(c, 0.15).cgColor, shade(c, 0.45).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let font = UIFont.systemFont(ofSize: 300, weight: .heavy)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white.withAlphaComponent(0.92)]
            let t = s as NSString
            let ts = t.size(withAttributes: attrs)
            t.draw(at: CGPoint(x: (size.width - ts.width) / 2, y: (size.height - ts.height) / 2), withAttributes: attrs)
        }
    }

    static func jpeg(_ img: UIImage) -> Data? { img.jpegData(compressionQuality: 0.85) }
}

/// Finds a picture online for folders without one (iTunes for music/audiobooks, radio-browser.info for stations).
/// Kid-safe: never explicit, and a guess from a folder name alone only accepts children's/family results.
enum ArtFinder {
    static var running = false
    static let stop: Set<String> = ["the", "a", "an", "and", "of", "to", "in", "on", "for", "with", "by", "ep", "unabridged", "abridged",
        "original", "score", "soundtrack", "edition", "deluxe", "remastered", "version", "vol", "volume", "includes", "song", "read",
        "along", "track", "audiobook", "radio", "fm", "am", "live", "story", "stories", "collection", "treasury", "complete",
        "adventures", "tales", "series", "book", "books", "podcast", "episode", "episodes", "full", "cd", "set", "box", "best"]

    static func run(force: Bool, changed: @escaping () -> Void) {
        guard !running, Store.bool("find_art") else { return }
        running = true
        DispatchQueue.global(qos: .utility).async {
            var any = false
            for f in Store.folders() where findFor(f, force: force) { any = true }
            DispatchQueue.main.async {
                running = false
                if any { changed() }
            }
        }
    }

    static func findFor(_ folder: String, force: Bool) -> Bool {
        let key = "art:" + folder
        let state = Store.ud.string(forKey: key) ?? ""
        if state == "off" || Art.hasPicture(folder) { return false }
        if !force, state.hasPrefix("none:"), let t = Double(state.dropFirst(5)), Date().timeIntervalSince1970 - t < 7 * 86400 { return false }
        let tracks = Store.listTracks(folder)
        guard !tracks.isEmpty else { return false }
        let data = Store.isLiveOnly(folder) ? stationLogo(tracks[0].name, folder) : albumArt(folder, tracks)
        if let d = data, let img = UIImage(data: d), img.size.width >= 48 {
            try? d.write(to: Store.dir(folder).appendingPathComponent(Art.autoCover))
            Store.set(key, "found")
            return true
        }
        Store.set(key, "none:\(Date().timeIntervalSince1970)")
        return false
    }

    static func reject(_ folder: String) {
        try? FileManager.default.removeItem(at: Store.dir(folder).appendingPathComponent(Art.autoCover))
        Store.set("art:" + folder, "off")
    }

    static func albumArt(_ folder: String, _ tracks: [Track]) -> Data? {
        var album: String?, artist: String?
        if let t = tracks.first(where: { !$0.live }) {
            let md = AVURLAsset(url: t.source).commonMetadata
            album = md.first(where: { $0.commonKey == .commonKeyAlbumName })?.stringValue
            artist = md.first(where: { $0.commonKey == .commonKeyArtist })?.stringValue
        }
        if let a = album?.trimmingCharacters(in: .whitespaces), !a.isEmpty {
            let q = artist.map { a + " " + $0 } ?? a
            if let hit = itunes(title: a, query: q, fromTags: true, artist: artist) { return get(hit) }
        }
        if let hit = itunes(title: folder, query: folder, fromTags: false, artist: nil) { return get(hit) }
        return nil
    }

    static func itunes(title: String, query: String, fromTags: Bool, artist: String?) -> String? {
        var best: String?, bestScore = 0.0
        for kind in ["media=audiobook", "media=music&entity=album"] {
            let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            guard let d = get("https://itunes.apple.com/search?term=\(q)&\(kind)&limit=10&explicit=No"),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let arr = j["results"] as? [[String: Any]] else { continue }
            for o in arr {
                let name = (o["collectionName"] as? String) ?? (o["trackName"] as? String) ?? ""
                guard let art = o["artworkUrl100"] as? String, !art.isEmpty else { continue }
                if (o["collectionExplicitness"] as? String)?.lowercased() == "explicit" { continue }
                if !fromTags && !kidsGenre(o["primaryGenreName"] as? String ?? "") { continue }
                var s = score(title, name)
                if fromTags, let a = artist { s = s * 0.8 + 0.2 * score(a, o["artistName"] as? String ?? "") }
                if s > bestScore { bestScore = s; best = art }
            }
        }
        guard let b = best, bestScore >= 0.6 else { return nil }
        return b.replacingOccurrences(of: "100x100bb", with: "600x600bb")
    }

    static func stationLogo(_ station: String, _ folder: String) -> Data? {
        for name in [station, folder] {
            let q = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            guard let d = get("https://all.api.radio-browser.info/json/stations/byname/\(q)?limit=10&hidebroken=true&order=votes&reverse=true"),
                  let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { continue }
            var best: String?, bestScore = 0.0
            for s in arr {
                guard let fav = s["favicon"] as? String, Store.isUrl(fav) else { continue }
                let sc = score(name, s["name"] as? String ?? "")
                if sc > bestScore { bestScore = sc; best = fav }
            }
            if let b = best, bestScore >= 0.6, let img = get(b) { return img }
        }
        return nil
    }

    static func kidsGenre(_ g: String) -> Bool {
        let l = g.lowercased()
        return ["child", "kid", "famil", "young", "lullab", "nursery"].contains { l.contains($0) }
    }

    static func words(_ s: String) -> Set<String> {
        let cleaned = s.lowercased().replacingOccurrences(of: "\\(.*?\\)|\\[.*?\\]", with: " ", options: .regularExpression)
        var out = Set<String>()
        for t in cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted) where t.count > 1 && !stop.contains(t) {
            out.insert(t.count > 3 && t.hasSuffix("s") ? String(t.dropLast()) : t)
        }
        return out
    }

    static func score(_ wanted: String, _ found: String) -> Double {
        let w = words(wanted), f = words(found)
        if w.isEmpty || f.isEmpty { return 0 }
        let hit = Double(w.intersection(f).count)
        return hit / Double(w.count) * 0.75 + hit / Double(f.count) * 0.25
    }

    /// Small blocking GET for the background search thread.
    static func get(_ s: String) -> Data? {
        guard let u = URL(string: s) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 10)
        req.setValue("WalkieTales-iOS (kids audio player; github.com/jaso1000/walkie-tales)", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if let h = r as? HTTPURLResponse, h.statusCode / 100 == 2, let d = d, d.count < 3_000_000 { out = d }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 12)
        return out
    }
}
