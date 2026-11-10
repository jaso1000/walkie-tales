import UIKit

/// Sleep sounds made on the phone (no downloads, work offline): rain, ocean waves, white noise and a heartbeat, as
/// 60-second WAV loops whose end blends into their start, in a "Sleep Sounds" folder that repeats each track.
/// Same sounds as the Android player. Made once; if a grown-up deletes the folder it stays deleted.
enum SleepSounds {
    static let folder = "Sleep Sounds"
    static let loopMark = ".loop"
    private static let rate = 22050, seconds = 60, n = 22050 * 60, fade = 22050 * 2

    static func loops(_ f: String?) -> Bool {
        guard let f = f else { return false }
        return FileManager.default.fileExists(atPath: Store.dir(f).appendingPathComponent(loopMark).path)
    }

    static func ensure(_ done: @escaping () -> Void) {
        if Store.ud.bool(forKey: "sleep_sounds_made") { return }
        DispatchQueue.global(qos: .utility).async {
            let dir = Store.dir(folder)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: dir.appendingPathComponent(loopMark).path, contents: Data())
                try wav(rain()).write(to: dir.appendingPathComponent("01 - Rain.wav"))
                try wav(ocean()).write(to: dir.appendingPathComponent("02 - Ocean Waves.wav"))
                try wav(white()).write(to: dir.appendingPathComponent("03 - White Noise.wav"))
                try wav(heartbeat()).write(to: dir.appendingPathComponent("04 - Heartbeat.wav"))
                try cover()?.write(to: dir.appendingPathComponent("cover.jpg"))
                Store.ud.set(true, forKey: "sleep_sounds_made")
                DispatchQueue.main.async(execute: done)
            } catch {
                NSLog("WalkieTales sleep sounds: \(error)")
            }
        }
    }

    // MARK: the sounds (-1...1, seamless loops)

    /// A small fixed random sequence, so every player makes the same sounds.
    private struct Rng { var s: UInt64; mutating func next() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(s >> 40) / Float(1 << 24) * 2 - 1 } }

    private static func seamless(_ x: [Float]) -> [Float] {
        var out = Array(x[0..<n])
        for i in 0..<fade { let t = Float(i) / Float(fade); out[i] = x[i] * t + x[n + i] * (1 - t) }
        return out
    }

    private static func white() -> [Float] {
        var r = Rng(s: 1)
        return seamless((0..<(n + fade)).map { _ in r.next() * 0.35 })
    }

    private static func pink(_ r: inout Rng, _ count: Int) -> [Float] { // Paul Kellet's filter
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
        var x = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let w = r.next()
            b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759; b2 = 0.96900 * b2 + w * 0.1538520
            b3 = 0.86650 * b3 + w * 0.3104856; b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980
            x[i] = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.11
            b6 = w * 0.115926
        }
        return x
    }

    private static func rain() -> [Float] {
        var r = Rng(s: 2)
        var x = pink(&r, n + fade).map { $0 * 0.9 }
        for _ in 0..<900 { // drops
            let at = Int((r.next() + 1) / 2 * Float(x.count - 401))
            let amp = 0.05 + (r.next() + 1) / 2 * 0.12
            for k in 0..<400 { x[at + k] += r.next() * amp * Float(exp(-Double(k) / 40)) }
        }
        return seamless(x)
    }

    private static func ocean() -> [Float] {
        var r = Rng(s: 3)
        var x = [Float](repeating: 0, count: n + fade)
        var last: Float = 0
        for i in 0..<x.count { last = (last + 0.02 * r.next()) / 1.02; x[i] = last * 3.5 }
        let s = seamless(x)
        return (0..<n).map { i in // a wave every 10 s
            let ph = Double(i % (rate * 10)) / Double(rate * 10)
            return s[i] * Float(0.25 + 0.75 * pow(sin(.pi * ph), 2))
        }
    }

    private static func heartbeat() -> [Float] {
        var y = [Float](repeating: 0, count: n)
        for b in 0..<seconds { thump(&y, b * rate, 1); thump(&y, b * rate + Int(Double(rate) * 0.28), 0.65) }
        return y
    }

    private static func thump(_ y: inout [Float], _ at: Int, _ amp: Float) {
        for k in 0..<Int(Double(rate) * 0.16) where at + k < y.count {
            let t = Double(k) / Double(rate)
            let env = sin(.pi * min(1, t / 0.012)) * exp(-t / 0.045)
            y[at + k] += amp * 0.8 * Float(env * (sin(2 * .pi * 48 * t) + 0.35 * sin(2 * .pi * 96 * t)))
        }
    }

    // MARK: files

    private static func wav(_ x: [Float]) -> Data {
        var d = Data()
        func u32(_ v: Int) { var le = UInt32(v).littleEndian; d.append(Data(bytes: &le, count: 4)) }
        func u16(_ v: Int) { var le = UInt16(v).littleEndian; d.append(Data(bytes: &le, count: 2)) }
        let bytes = x.count * 2
        d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(bytes)
        var samples = x.map { Int16(max(-32767, min(32767, ($0 * 32767).rounded()))).littleEndian }
        d.append(Data(bytes: &samples, count: bytes))
        return d
    }

    private static func cover() -> Data? {
        let size = CGSize(width: 600, height: 600)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [UIColor(red: 0.106, green: 0.165, blue: 0.42, alpha: 1).cgColor,
                                                                                     UIColor(red: 0.04, green: 0.06, blue: 0.18, alpha: 1).cgColor] as CFArray, locations: nil)!
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: 600), options: [])
            var r = Rng(s: 4)
            UIColor(white: 1, alpha: 0.8).setFill()
            for _ in 0..<40 {
                let x = CGFloat((r.next() + 1) / 2 * 600), y = CGFloat((r.next() + 1) / 2 * 600), s = CGFloat(3 + (r.next() + 1) * 3)
                c.fillEllipse(in: CGRect(x: x, y: y, width: s, height: s))
            }
            UIColor(red: 1, green: 0.91, blue: 0.66, alpha: 1).setFill()
            c.fillEllipse(in: CGRect(x: 330 - 132, y: 270 - 132, width: 264, height: 264))
            UIColor(red: 0.08, green: 0.13, blue: 0.31, alpha: 1).setFill()
            c.fillEllipse(in: CGRect(x: 390 - 120, y: 228 - 120, width: 240, height: 240))
        }
        return img.jpegData(compressionQuality: 0.9)
    }
}
