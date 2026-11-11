import UIKit

/// The voice messages folder (recorded on the remote or in Grown-up settings → Messages). It gets its own picture,
/// drawn here, so the automatic cover search never puts a stranger's album on it. An older "From Mum & Dad" folder is
/// renamed. Same as the Android player (Messages.java).
enum Messages {
    static let folder = "Messages"
    private static let old = "From Mum & Dad"

    /// On start: rename the old folder and make sure the folder (if there is one) has its picture.
    static func ensure() {
        let fm = FileManager.default
        let oldDir = Store.dir(old), dir = Store.dir(folder)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: oldDir.path, isDirectory: &isDir), isDir.boolValue {
            if !fm.fileExists(atPath: dir.path) {
                try? fm.moveItem(at: oldDir, to: dir)
            } else { // both exist: move the old messages across
                for u in (try? fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil)) ?? [] where !Store.imageExt.contains(u.pathExtension.lowercased()) {
                    try? fm.moveItem(at: u, to: unique(in: dir, u.lastPathComponent))
                }
            }
        }
        if fm.fileExists(atPath: dir.path) { ensureCover() }
    }

    /// After a message is saved into the folder.
    static func ensureCover() {
        let dir = Store.dir(folder)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(Art.autoCover)) // a cover the online search guessed
        let f = dir.appendingPathComponent("cover.jpg")
        if !FileManager.default.fileExists(atPath: f.path) { try? draw().write(to: f) }
    }

    static func unique(in dir: URL, _ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var out = dir.appendingPathComponent(name), i = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"); i += 1
        }
        return out
    }

    /// A warm envelope with a heart: "a message for you".
    private static func draw() -> Data {
        let s: CGFloat = 600
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: fmt).image { ctx in
            let c = ctx.cgContext
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [UIColor(red: 1, green: 0.54, blue: 0.5, alpha: 1).cgColor,
                                        UIColor(red: 0.94, green: 0.38, blue: 0.57, alpha: 1).cgColor] as CFArray, locations: nil)!
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: s, y: s), options: [])
            let env = CGRect(x: s * 0.17, y: s * 0.30, width: s * 0.66, height: s * 0.44)
            UIColor(white: 0, alpha: 0.2).setFill()
            UIBezierPath(roundedRect: env.offsetBy(dx: 0, dy: 10), cornerRadius: 28).fill()
            UIColor(red: 1, green: 0.985, blue: 0.96, alpha: 1).setFill()
            UIBezierPath(roundedRect: env, cornerRadius: 28).fill()
            let flap = UIBezierPath()
            flap.move(to: CGPoint(x: env.minX + 18, y: env.minY + 18))
            flap.addLine(to: CGPoint(x: s * 0.5, y: s * 0.53))
            flap.addLine(to: CGPoint(x: env.maxX - 18, y: env.minY + 18))
            flap.lineWidth = 10; flap.lineJoinStyle = .round; flap.lineCapStyle = .round
            UIColor(red: 0.95, green: 0.78, blue: 0.81, alpha: 1).setStroke()
            flap.stroke()
            let cx = s * 0.5, cy = s * 0.53, r = s * 0.075
            let heart = UIBezierPath()
            heart.move(to: CGPoint(x: cx, y: cy + r * 1.35))
            heart.addCurve(to: CGPoint(x: cx, y: cy - r * 0.75), controlPoint1: CGPoint(x: cx - r * 2.2, y: cy - r * 0.2), controlPoint2: CGPoint(x: cx - r * 1.1, y: cy - r * 1.9))
            heart.addCurve(to: CGPoint(x: cx, y: cy + r * 1.35), controlPoint1: CGPoint(x: cx + r * 1.1, y: cy - r * 1.9), controlPoint2: CGPoint(x: cx + r * 2.2, y: cy - r * 0.2))
            heart.close()
            UIColor(red: 0.9, green: 0.22, blue: 0.35, alpha: 1).setFill()
            heart.fill()
        }
        return img.jpegData(compressionQuality: 0.9) ?? Data()
    }
}
