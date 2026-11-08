import AVFoundation
import SystemConfiguration
import UIKit

/// "Pick something": a grid of covers (works without cards).
final class LibraryViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onPick: ((String) -> Void)?
    private var items: [String] = []
    private var collection: UICollectionView!
    private var covers: [String: UIImage] = [:]

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)
        let title = UILabel()
        title.text = "Pick something"
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textColor = .white
        let close = RoundButton()
        close.setup(icon: "xmark", size: 48, color: UIColor(white: 1, alpha: 0.15), iconSize: 18)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        let head = UIStackView(arrangedSubviews: [title, UIView(), close])
        head.alignment = .center
        head.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(head)

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 18
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.register(TileCell.self, forCellWithReuseIdentifier: "t")
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 24, right: 0)
        view.addSubview(collection)
        NSLayoutConstraint.activate([
            head.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            head.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            head.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            head.heightAnchor.constraint(equalToConstant: 56),
            collection.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            collection.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            collection.topAnchor.constraint(equalTo: head.bottomAnchor),
            collection.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        reload()
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    /// No internet: radio stations can't play, so don't offer them.
    func reload() {
        let online = Reachability.online
        items = Store.folders().filter { f in
            let t = Store.listTracks(f)
            return !t.isEmpty && (online || !t.allSatisfy { $0.live })
        }
        if items.count > 1 { items.append(Store.ALL) }
        for f in items where f != Store.ALL { if let c = Art.cachedTile(f) { covers[f] = c } } // remembered: show at once
        collection?.reloadData()
        let list = items.filter { $0 != Store.ALL && covers[$0] == nil }
        DispatchQueue.global(qos: .userInitiated).async {
            for f in list {
                if let c = Art.tile(f) {
                    DispatchQueue.main.async {
                        self.covers[f] = c
                        if let i = self.items.firstIndex(of: f) { self.collection.reloadItems(at: [IndexPath(item: i, section: 0)]) }
                    }
                }
            }
        }
    }

    static func info(_ f: String, player: Player) -> String {
        if f == player.folder && player.isPlaying { return "Now playing" }
        if f == Store.ALL { return "Shuffle it all" }
        let tracks = Store.listTracks(f)
        if !tracks.isEmpty && tracks.allSatisfy({ $0.live }) { return tracks.count == 1 ? "Live radio" : "\(tracks.count) radio stations" }
        let n = tracks.count
        let at = Store.position(f).0
        if Store.flag("resume", f, true) && !Store.flag("shuffle", f, false) && at > 0 && at < n { return "Track \(at + 1) of \(n)" }
        return "\(n) " + (n == 1 ? "track" : "tracks")
    }

    func collectionView(_ c: UICollectionView, numberOfItemsInSection s: Int) -> Int { items.count }

    func collectionView(_ c: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = c.dequeueReusableCell(withReuseIdentifier: "t", for: ip) as! TileCell
        let f = items[ip.item]
        let all = f == Store.ALL
        let color = all ? UIColor(red: 0.88, green: 0.33, blue: 0.6, alpha: 1) : Art.colorFor(f)
        cell.image.image = covers[f] ?? Art.letter(all ? "★" : String(f.prefix(1)).uppercased(), color)
        cell.name.text = all ? "Everything" : f
        cell.name.textColor = f == Player.shared.folder ? Art.tint(color, 0.35) : .white
        cell.info.text = Self.info(f, player: Player.shared)
        return cell
    }

    func collectionView(_ c: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt ip: IndexPath) -> CGSize {
        let w = (c.bounds.width - 16) / 2
        return CGSize(width: w, height: w + 66)
    }

    func collectionView(_ c: UICollectionView, didSelectItemAt ip: IndexPath) {
        let f = items[ip.item]
        dismiss(animated: true) { self.onPick?(f) }
    }
}

final class TileCell: UICollectionViewCell {
    let image = UIImageView(), name = UILabel(), info = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.layer.cornerRadius = 20
        image.layer.cornerCurve = .continuous
        name.font = .systemFont(ofSize: 16, weight: .bold)
        name.numberOfLines = 2
        info.font = .systemFont(ofSize: 13)
        info.textColor = UIColor(white: 1, alpha: 0.55)
        let s = UIStackView(arrangedSubviews: [image, name, info])
        s.axis = .vertical
        s.spacing = 4
        s.setCustomSpacing(8, after: image)
        s.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), s.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            s.topAnchor.constraint(equalTo: contentView.topAnchor),
            image.heightAnchor.constraint(equalTo: image.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool { didSet { UIView.animate(withDuration: 0.1) { self.image.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity } } }
}

/// Every track in the folder, as a bottom sheet.
final class TracksViewController: UITableViewController {
    var onPick: ((Int) -> Void)?
    let accent: UIColor
    let thumb: UIImage?
    private var lengths: [Int: String] = [:]

    init(accent: UIColor, art: UIImage?) {
        self.accent = accent
        thumb = art
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        tableView.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 1)
        tableView.separatorStyle = .none
        tableView.rowHeight = 66
        tableView.register(TrackCell.self, forCellReuseIdentifier: "r")
        let p = Player.shared
        // header: cover · title / count
        let head = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 96))
        let img = UIImageView(image: thumb)
        img.contentMode = .scaleAspectFill
        img.clipsToBounds = true
        img.layer.cornerRadius = 14
        let t = UILabel()
        t.text = Store.label(p.folder ?? "")
        t.font = .systemFont(ofSize: 21, weight: .bold)
        t.textColor = .white
        let c = UILabel()
        let liveOnly = p.tracks.allSatisfy { $0.live }
        c.text = "\(p.tracks.count) " + (liveOnly ? (p.tracks.count == 1 ? "station" : "stations") : (p.tracks.count == 1 ? "track" : "tracks"))
        c.font = .systemFont(ofSize: 14)
        c.textColor = UIColor(white: 1, alpha: 0.65)
        let texts = UIStackView(arrangedSubviews: [t, c])
        texts.axis = .vertical
        let row = UIStackView(arrangedSubviews: [img, texts])
        row.spacing = 14
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        head.addSubview(row)
        NSLayoutConstraint.activate([
            img.widthAnchor.constraint(equalToConstant: 60), img.heightAnchor.constraint(equalToConstant: 60),
            row.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: 18), row.trailingAnchor.constraint(equalTo: head.trailingAnchor, constant: -18),
            row.centerYAnchor.constraint(equalTo: head.centerYAnchor, constant: 8),
        ])
        tableView.tableHeaderView = head
        // track lengths, read in the background
        let list = p.tracks
        DispatchQueue.global(qos: .utility).async {
            for (i, tr) in list.enumerated() where !tr.live && i < 400 {
                let d = CMTimeGetSeconds(AVURLAsset(url: tr.source).duration)
                guard d.isFinite, d > 0 else { continue }
                DispatchQueue.main.async {
                    self.lengths[i] = PlayerViewController.fmt(d)
                    if let cell = self.tableView.cellForRow(at: IndexPath(row: i, section: 0)) as? TrackCell { cell.length.text = self.lengths[i] }
                }
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let i = Player.shared.index
        if Player.shared.tracks.indices.contains(i) { tableView.scrollToRow(at: IndexPath(row: i, section: 0), at: .middle, animated: false) }
    }

    override func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { Player.shared.tracks.count }

    override func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = t.dequeueReusableCell(withIdentifier: "r", for: ip) as! TrackCell
        let p = Player.shared
        let tr = p.tracks[ip.row]
        let cur = ip.row == p.index
        cell.configure(number: ip.row + 1, name: tr.name, current: cur, playing: cur && p.isPlaying, live: tr.live, accent: accent)
        cell.length.text = tr.live ? "LIVE" : lengths[ip.row]
        return cell
    }

    override func tableView(_ t: UITableView, didSelectRowAt ip: IndexPath) {
        dismiss(animated: true) { self.onPick?(ip.row) }
    }
}

final class TrackCell: UITableViewCell {
    let badge = UILabel(), name = UILabel(), length = UILabel()
    private let bg = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        bg.layer.cornerRadius = 16
        bg.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bg)
        badge.textAlignment = .center
        badge.font = .systemFont(ofSize: 15, weight: .bold)
        badge.layer.cornerRadius = 20
        badge.clipsToBounds = true
        name.font = .systemFont(ofSize: 17)
        name.numberOfLines = 2
        length.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        length.textColor = UIColor(white: 1, alpha: 0.55)
        let s = UIStackView(arrangedSubviews: [badge, name, length])
        s.spacing = 14
        s.alignment = .center
        s.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(s)
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12), bg.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            bg.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2), bg.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
            s.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 10), s.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),
            s.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 40), badge.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(number: Int, name n: String, current: Bool, playing: Bool, live: Bool, accent: UIColor) {
        badge.text = current ? (playing ? "♫" : "▶") : "\(number)"
        badge.backgroundColor = current ? accent : UIColor(white: 1, alpha: 0.12)
        badge.textColor = .white
        name.text = n
        name.textColor = current ? Art.tint(accent, 0.45) : .white
        name.font = .systemFont(ofSize: 17, weight: current ? .bold : .regular)
        bg.backgroundColor = current ? Art.shade(accent, 0.25).withAlphaComponent(0.55) : .clear
    }
}

/// Is there a usable internet connection right now?
enum Reachability {
    static var online: Bool {
        var zero = sockaddr_in()
        zero.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zero.sin_family = sa_family_t(AF_INET)
        guard let r = withUnsafePointer(to: &zero, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { SCNetworkReachabilityCreateWithAddress(nil, $0) } }) else { return true }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(r, &flags) else { return true }
        return flags.contains(.reachable) && !flags.contains(.connectionRequired)
    }
}
