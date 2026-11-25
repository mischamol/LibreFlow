import Foundation

/// A GPX track as a Polar route: /U/0/ROUTES/<n>/PROUTE.BPB (`PbPlannedRoute`) plus a route favorite in /U/0/FAV/<nn>/.
/// Format verified on a Grit X (CLAUDE.md, 25 Nov 2026): points are whole metres east (x) / north (y) of the start,
/// with time offset (ms), altitude offset and distance so far (m). Byte-identical to `polar_ble.py route-build`, whose
/// encoder reproduces a Polar Flow route byte for byte; that output was written and shown on the watch.
struct PlannedRoute: Equatable, Codable {
    struct Point: Equatable, Codable { var x: Int, y: Int, t: Int, z: Int, d: Int }
    var id: UInt64, name: String, lat: Double, lon: Double, alt: Double
    var points: [Point], length: Double, gpxLength: Double, gpxCount: Int
    var latLon: [(Double, Double)] { points.map { (lat + Double($0.y) / 111_320, lon + Double($0.x) / (111_320 * cos(lat * .pi / 180))) } }
    static func == (a: PlannedRoute, b: PlannedRoute) -> Bool { a.id == b.id && a.name == b.name && a.points == b.points }

    static let maxPoints = 500   // a 15 km Polar Flow route had 466 points; stay in that range until tested further
    static let maxNameBytes = 45

    enum GPXError: LocalizedError {
        case noPoints
        var errorDescription: String? { "The file has no track or route points." }
    }

    /// Parse a GPX file (tracks, or else a route) and simplify it the way the watch can store it.
    init(gpx data: Data, fallbackName: String, now: Date = Date()) throws {
        let p = GPXReader(data)
        try self.init(points: (p.track.isEmpty ? p.route : p.track).map { ($0.lat, $0.lon, $0.ele, $0.time) },
                      name: p.name?.isEmpty == false ? p.name! : fallbackName, now: now)
    }

    /// A run's GPS route from the app's raw data ([[t, lat, lon], …]) as a route.
    init(run raw: [[Double]], name: String, now: Date = Date()) throws {
        try self.init(points: raw.filter { $0.count >= 3 }.map { ($0[1], $0[2], nil, $0[0]) }, name: name, now: now)
    }

    /// A route read from the watch (to keep LibreFlow routes that are not in the library yet).
    init?(proute b: [UInt8]) {
        let m = PBMessage(b)
        guard let rid = m.msg(1)?.int(1), let loc = m.msg(4) else { return nil }
        func dbl(_ v: PBValue?) -> Double? { if case .fixed64(let x)? = v { return x.withUnsafeBytes { Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) } }; return nil }
        let zz = { (n: Int) in (n >> 1) ^ -(n & 1) }
        id = UInt64(rid); name = m.msg(2)?.first(1)?.data.map { String(decoding: $0, as: UTF8.self) } ?? "Route"
        lat = dbl(loc.first(1)) ?? 0; lon = dbl(loc.first(2)) ?? 0; alt = Double(m.float(5) ?? 0)
        points = m.all(6).compactMap { $0.data.map(PBMessage.init) }.map { q in Point(x: zz(q.int(1)), y: zz(q.int(2)), t: q.int(3), z: zz(q.int(4)), d: q.int(6)) }
        length = Double(m.float(3) ?? 0); gpxLength = length; gpxCount = points.count
    }

    private init(points input: [(lat: Double, lon: Double, ele: Double?, time: Double?)], name givenName: String, now: Date) throws {
        var pts = input.map { GPXReader.P(lat: $0.lat, lon: $0.lon, ele: $0.ele, time: $0.time) }
        pts = pts.enumerated().filter { $0.offset == 0 || ($0.element.lat, $0.element.lon) != (pts[$0.offset - 1].lat, pts[$0.offset - 1].lon) }.map(\.element)
        guard pts.count >= 2 else { throw GPXError.noPoints }
        let lat0 = pts[0].lat, lon0 = pts[0].lon, k = 111_320 * cos(lat0 * .pi / 180)
        let xy = pts.map { (($0.lon - lon0) * k, ($0.lat - lat0) * 111_320) }
        var gpxLen = 0.0
        for i in 1..<xy.count { gpxLen += hypot(xy[i].0 - xy[i - 1].0, xy[i].1 - xy[i - 1].1) }
        var tol = 2.0, idx = Self.simplify(xy, tol)
        while idx.count > Self.maxPoints { tol *= 1.3; idx = Self.simplify(xy, tol) }
        let times = pts.map(\.time)
        let hasT = times.allSatisfy { $0 != nil } && times.last!! > times.first!!
        let ele0 = pts[0].ele
        // length and distance so far along the stored (rounded) points: the watch measures the route that way
        var out: [Point] = [], d = 0.0, prev: (Int, Int)?
        for i in idx {
            let x = Int(xy[i].0.rounded()), y = Int(xy[i].1.rounded())
            if let prev { d += hypot(Double(x - prev.0), Double(y - prev.1)) }
            prev = (x, y)
            let t = hasT ? Int((times[i]! - times[0]!).rounded()) * 1000 : Int((d / 3).rounded()) * 1000   // no times: 3 m/s
            let z = ele0 != nil && pts[i].ele != nil ? Int((pts[i].ele! - ele0!).rounded()) : 0
            out.append(Point(x: x, y: y, t: t, z: z, d: Int(d.rounded())))
        }
        id = 900_000_000 + UInt64(Int(now.timeIntervalSince1970) % 100_000_000)
        name = Self.clip(givenName)
        lat = lat0; lon = lon0; alt = ele0 ?? 0
        points = out; length = d; gpxLength = gpxLen; gpxCount = pts.count
    }

    /// at most 45 UTF-8 bytes (the watch's favorite list keeps 46), cut on a character boundary
    static func clip(_ s: String) -> String {
        var r = ""
        for c in s.trimmingCharacters(in: .whitespacesAndNewlines) where r.utf8.count + String(c).utf8.count <= maxNameBytes { r.append(c) }
        return r.isEmpty ? "Route" : r
    }

    /// Douglas–Peucker on metre coordinates; returns the kept indices in order
    static func simplify(_ xy: [(Double, Double)], _ tol: Double) -> [Int] {
        var keep: Set<Int> = [0, xy.count - 1], stack = [(0, xy.count - 1)]
        while let (a, b) = stack.popLast() {
            let (x1, y1) = xy[a], (x2, y2) = xy[b], dx = x2 - x1, dy = y2 - y1, L = hypot(dx, dy)
            var best = 0.0, bi: Int?
            if b > a + 1 {
                for i in (a + 1)..<b {
                    let (x, y) = xy[i]
                    let dd = L > 0 ? abs(dy * (x - x1) - dx * (y - y1)) / L : hypot(x - x1, y - y1)
                    if dd > best { best = dd; bi = i }
                }
            }
            if let bi, best > tol { keep.insert(bi); stack += [(a, bi), (bi, b)] }
        }
        return keep.sorted()
    }

    // MARK: encoding
    func proute(now: Date = Date(), uuid: UUID = UUID()) -> [UInt8] {
        var b = PB.ld(1, PB.vi(1, id)) + PB.text(2, name) + PB.f32(3, length)
        b += PB.ld(4, PB.f64(1, lat) + PB.f64(2, lon)) + PB.f32(5, alt)
        for p in points { b += PB.ld(6, PB.zig(1, p.x) + PB.zig(2, p.y) + PB.vi(3, p.t) + PB.zig(4, p.z) + PB.vi(6, p.d)) }
        let dt = PB.dateTime(now, trusted: true)
        return b + PB.vi(9, 1) + PB.ld(10, dt) + PB.ld(11, dt) + PB.ld(12, Array(uuid.uuidString.lowercased().utf8))
    }

    /// route favorite: exercise_target {1: 3 ROUTE, 2: {1 sport}, 4: {}, 5: {1 route id}} (as Polar Flow writes it)
    func favorite(sport: Int = 1) -> [UInt8] {
        return PB.text(2, name) + PB.ld(6, PB.vi(1, 3) + PB.ld(2, PB.vi(1, sport)) + PB.ld(4, []) + PB.ld(5, PB.vi(1, id)))
    }

    func idFile(now: Date = Date()) -> [UInt8] { PB.favoriteIdFile(id, now: now) }
}

/// Minimal GPX reader: track points (trkpt) and route points (rtept) with elevation and time, and the first name.
final class GPXReader: NSObject, XMLParserDelegate {
    struct P { var lat: Double, lon: Double, ele: Double?, time: Double? }
    var track: [P] = [], route: [P] = []
    private var names: [String: String] = [:]   // first name per parent: trk, rte, metadata
    var name: String? { names["trk"] ?? names["rte"] ?? names["metadata"] }
    private var cur: P?, inTrk = false, text = "", depth: [String] = []
    private let iso = ISO8601DateFormatter(), isoFrac = ISO8601DateFormatter()

    init(_ data: Data) {
        super.init()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let p = XMLParser(data: data); p.delegate = self; p.parse()
    }
    private func local(_ n: String) -> String { n.split(separator: ":").last.map(String.init) ?? n }

    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        let n = local(e); depth.append(n); text = ""
        if n == "trkpt" || n == "rtept", let la = a["lat"].flatMap(Double.init), let lo = a["lon"].flatMap(Double.init) {
            cur = P(lat: la, lon: lo, ele: nil, time: nil); inTrk = n == "trkpt"
        }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        let n = local(e), t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        depth.removeLast()
        if cur != nil {
            if n == "ele" { cur!.ele = Double(t) }
            if n == "time" { cur!.time = (isoFrac.date(from: t) ?? iso.date(from: t))?.timeIntervalSince1970 }
            if n == "trkpt" || n == "rtept" { if inTrk { track.append(cur!) } else { route.append(cur!) }; cur = nil }
        } else if n == "name", !t.isEmpty, let parent = depth.last, ["trk", "rte", "metadata"].contains(parent), names[parent] == nil {
            names[parent] = t
        }
        text = ""
    }
}

/// The routes kept on this iPhone (Documents/routes/library.json). Checked ones belong on the watch: the next Sync
/// adds them, and removes LibreFlow routes that are unchecked or deleted here (`RouteSync`).
@MainActor
final class RouteLibrary: ObservableObject {
    static let shared = RouteLibrary()
    struct Entry: Codable, Identifiable, Equatable {
        var route: PlannedRoute
        var checked: Bool
        var onWatch: Bool = false          // as found at the last Sync
        var added: Date = Date()
        var source: String                 // "GPX file", "Run 12 Nov 2026", "From the watch"
        var id: UInt64 { route.id }
    }
    @Published private(set) var entries: [Entry] = []
    @Published var flowRoutes: [String] = []   // Polar Flow's routes on the watch at the last Sync (listed, never changed)
    @Published var lastSync: String?
    /// what /U/0/ROUTES/ held at the last Sync (folder, file size, id, name): unchanged folders are not read again
    struct Snap: Codable { var folder: Int, size: Int, id: UInt64, name: String }
    var snapshot: [Snap] = []

    private var url: URL { TrainingStore.shared.root.appendingPathComponent("routes/library.json") }
    private struct File: Codable { var entries: [Entry]; var flowRoutes: [String]; var lastSync: String?; var snapshot: [Snap]? }

    init() {
        if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) {
            entries = f.entries; flowRoutes = f.flowRoutes; lastSync = f.lastSync; snapshot = f.snapshot ?? []
        }
    }
    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(File(entries: entries, flowRoutes: flowRoutes, lastSync: lastSync, snapshot: snapshot)) { try? d.write(to: url, options: .atomic) }
    }

    /// Route ids must be unique (they link the favorite to the route): bump until free.
    func add(_ r: PlannedRoute, source: String, checked: Bool = true) {
        var r = r
        while entries.contains(where: { $0.id == r.id }) { r.id += 1 }
        entries.insert(Entry(route: r, checked: checked, source: source), at: 0); save()
    }
    func setChecked(_ id: UInt64, _ on: Bool) { if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].checked = on; save() } }
    func rename(_ id: UInt64, _ name: String) { if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].route.name = PlannedRoute.clip(name); save() } }
    func delete(_ id: UInt64) { entries.removeAll { $0.id == id }; save() }
    /// Settings › Delete all data. LibreFlow routes still on the watch are adopted again at the next Sync.
    func reset() { entries = []; flowRoutes = []; lastSync = nil; snapshot = []; try? FileManager.default.removeItem(at: url) }
    fileprivate func synced(onWatch: Set<UInt64>, adopted: [PlannedRoute], flow: [String], summary: String, snapshot: [Snap]) {
        self.snapshot = snapshot
        for r in adopted where !entries.contains(where: { $0.id == r.id }) { entries.append(Entry(route: r, checked: true, source: "From the watch")) }
        for i in entries.indices { entries[i].onWatch = onWatch.contains(entries[i].id) }
        flowRoutes = flow; lastSync = summary; save()
    }
}

/// Part of every Sync: make the LibreFlow routes on the watch match the checked routes in the library. Both
/// /U/0/ROUTES/<n>/ and /U/0/FAV/<nn>/ must stay numbered without gaps from 0 (the watch stops at the first gap: tested
/// 25 Nov 2026). A route favorite refers to the route id, not the folder, so a route file can move to another folder
/// unchanged. Only routes and favorites with an id ≥ 900000000 (written by LibreFlow) are moved, rewritten or removed.
@MainActor
enum RouteSync {
    private struct Fav { var slot: Int, id: UInt64, routeId: UInt64?, idFile: [UInt8], tst: [UInt8] }
    private struct OnWatch { var folder: Int, id: UInt64, name: String, size: Int, file: [UInt8]?; var ours: Bool { id >= WatchFavorites.ourIds } }

    private static let favDir = PolarWatch.favDir, routeDir = PolarWatch.routeDir, gapless = PolarWatch.gapless

    static func reconcile(_ w: PolarWatch, log: (String) -> Void) async throws {
        let lib = RouteLibrary.shared
        var routes: [OnWatch] = []
        for n in try await w.folderNumbers("/U/0/ROUTES/") {
            let size = try await w.ls(routeDir(n)).first { $0.name == "PROUTE.BPB" }?.size ?? -1
            if let c = lib.snapshot.first(where: { $0.folder == n && $0.size == size }) {   // unchanged since the last Sync
                routes.append(OnWatch(folder: n, id: c.id, name: c.name, size: size, file: nil)); continue
            }
            let b = try await w.get(routeDir(n) + "PROUTE.BPB"), m = PBMessage(b)
            routes.append(OnWatch(folder: n, id: UInt64(m.msg(1)?.int(1) ?? 0), name: m.msg(2)?.first(1)?.data.map { String(decoding: $0, as: UTF8.self) } ?? "?", size: b.count, file: b))
        }
        func file(_ r: OnWatch) async throws -> [UInt8] { if let f = r.file { return f }; return try await w.get(routeDir(r.folder) + "PROUTE.BPB") }
        var favs: [Fav] = []
        for k in try await w.folderNumbers("/U/0/FAV/") {
            let idFile = try await w.get(favDir(k) + "ID.BPB"), tst = try await w.get(favDir(k) + "TST.BPB")
            let target = PBMessage(tst).msg(6)
            favs.append(Fav(slot: k, id: UInt64(PBMessage(idFile).int(1)), routeId: target?.int(1) == 3 ? target?.msg(5).map { UInt64($0.int(1)) } : nil, idFile: idFile, tst: tst))
        }
        let flow = routes.filter { !$0.ours }.map(\.name)
        // LibreFlow routes on the watch that this library does not know (e.g. sent with polar_ble.py): keep them
        var adopted: [PlannedRoute] = []
        for r in routes where r.ours && !lib.entries.contains(where: { $0.id == r.id }) { if let p = PlannedRoute(proute: try await file(r)) { adopted.append(p) } }
        let wanted = Dictionary(uniqueKeysWithValues: lib.entries.filter(\.checked).map { ($0.id, $0.route) } + adopted.map { ($0.id, $0) })
        guard gapless(routes.map(\.folder)), gapless(favs.map(\.slot)) else {
            log("Routes: the routes or favorites on the watch have a gap; routes were not changed.")
            lib.synced(onWatch: Set(routes.map(\.id)), adopted: adopted, flow: flow, summary: "Routes not updated: the watch's lists have a gap.", snapshot: []); return
        }
        var removed = 0, added = 0, renamed = 0

        // 1. remove LibreFlow routes that are no longer wanted (unchecked or deleted here)
        for r in routes.filter({ $0.ours && wanted[$0.id] == nil }) {
            guard let cur = routes.first(where: { $0.id == r.id }), let top = routes.last else { continue }
            let slots = favs.filter { $0.routeId == r.id }.map(\.slot).sorted(by: >)
            // check first that nothing from Polar Flow would have to move: then change nothing for this route
            var sim = favs, blocked = top.folder != cur.folder && !top.ours
            for slot in slots where !blocked {
                let l = sim.last!
                if l.slot != slot {
                    if l.id < WatchFavorites.ourIds { blocked = true; break }
                    sim[sim.firstIndex { $0.slot == slot }!] = Fav(slot: slot, id: l.id, routeId: l.routeId, idFile: l.idFile, tst: l.tst)
                }
                sim.removeLast()
            }
            if blocked { log("Routes: \"\(r.name)\" kept: removing it would leave a gap before a Polar Flow item."); continue }
            for slot in slots {
                let last = favs.last!
                if last.slot != slot {   // the last favorite moves into the freed place, unchanged
                    try await w.put(favDir(slot) + "TST.BPB", last.tst); try await w.put(favDir(slot) + "ID.BPB", last.idFile)
                    favs[favs.firstIndex { $0.slot == slot }!] = Fav(slot: slot, id: last.id, routeId: last.routeId, idFile: last.idFile, tst: last.tst)
                }
                try await w.removeFolder(favDir(last.slot))
                favs.removeLast()
            }
            if top.folder != cur.folder {   // the last route moves into the freed folder, unchanged
                let data = try await file(top)
                try await w.put(routeDir(cur.folder) + "PROUTE.BPB", data)
                guard try await w.get(routeDir(cur.folder) + "PROUTE.BPB") == data else { throw PolarError.protocolError(-1) }
                routes[routes.firstIndex { $0.folder == cur.folder }!] = OnWatch(folder: cur.folder, id: top.id, name: top.name, size: data.count, file: data)
            }
            try await w.removeFolder(routeDir(top.folder))
            routes.removeLast()
            removed += 1; log("Routes: removed \"\(r.name)\".")
        }

        // 2. renamed here: rewrite the route file and its favorite in place
        for (i, r) in routes.enumerated() where r.ours {
            guard let want = wanted[r.id], want.name != r.name else { continue }
            let file = want.proute()
            try await w.put(routeDir(r.folder) + "PROUTE.BPB", file)
            for f in favs where f.routeId == r.id { try await w.put(favDir(f.slot) + "TST.BPB", want.favorite()) }
            routes[i].name = want.name; routes[i].file = file; routes[i].size = file.count; renamed += 1
        }

        // 3. add checked routes that are not on the watch yet, at the end of both lists
        for (id, r) in wanted.sorted(by: { $0.key < $1.key }) where !routes.contains(where: { $0.id == id }) {
            let n = routes.count, k = favs.count, file = r.proute()
            try await w.put(routeDir(n), [])
            try await w.put(routeDir(n) + "PROUTE.BPB", file)
            try await w.put(favDir(k), [])
            try await w.put(favDir(k) + "TST.BPB", r.favorite())
            let idFile = r.idFile()
            try await w.put(favDir(k) + "ID.BPB", idFile)
            guard try await w.get(routeDir(n) + "PROUTE.BPB") == file else { throw PolarError.protocolError(-1) }
            routes.append(OnWatch(folder: n, id: id, name: r.name, size: file.count, file: file))
            favs.append(Fav(slot: k, id: r.id, routeId: id, idFile: idFile, tst: r.favorite()))
            added += 1; log("Routes: added \"\(r.name)\" (\(String(format: "%.1f", r.length / 1000)) km).")
        }
        let summary = added + removed + renamed == 0 ? "Routes on the watch are up to date."
            : "Routes: \(added) added, \(removed) removed\(renamed > 0 ? ", \(renamed) renamed" : "")."
        log(summary)
        lib.synced(onWatch: Set(routes.map(\.id)), adopted: adopted, flow: flow, summary: summary,
                   snapshot: routes.map { RouteLibrary.Snap(folder: $0.folder, size: $0.size, id: $0.id, name: $0.name) })
    }
}
