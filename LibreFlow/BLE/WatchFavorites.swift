import Foundation

/// One session of the running plan as a Polar "phased" training favorite (`PbTrainingSessionTarget`, see CLAUDE.md:
/// format verified on a Grit X). Built from `appPlanFavorites()` in the analysis page.
struct PlanFavorite: Identifiable, Equatable {
    struct Phase: Equatable {
        var name: String, distance: Bool, metres: Int, seconds: Int, pace: Bool, lo: Int, hi: Int, repeatCount: Int?, jump: Int?
    }
    var id: String { date + name }
    var date: String, name: String, description: String, phases: [Phase]

    init?(_ d: [String: Any]) {
        guard let date = d["date"] as? String, let name = d["name"] as? String, let ps = d["phases"] as? [[String: Any]], !ps.isEmpty else { return nil }
        self.date = date; self.name = name; description = d["description"] as? String ?? ""
        phases = ps.map { p in
            Phase(name: p["name"] as? String ?? "", distance: (p["goal"] as? String) == "distance",
                  metres: (p["metres"] as? NSNumber)?.intValue ?? 0, seconds: (p["seconds"] as? NSNumber)?.intValue ?? 0,
                  pace: (p["intensity"] as? String) == "pace", lo: (p["lo"] as? NSNumber)?.intValue ?? 1, hi: (p["hi"] as? NSNumber)?.intValue ?? 5,
                  repeatCount: (p["repeat"] as? NSNumber)?.intValue, jump: (p["jump"] as? NSNumber)?.intValue)
        }
    }

    // MARK: encoding (only constructs seen in Polar Flow favorites or tested on the watch)
    private static func vi(_ f: Int, _ v: Int) -> [UInt8] { PB.varint(UInt64(f << 3)) + PB.varint(UInt64(max(0, v))) }
    private static func ld(_ f: Int, _ b: [UInt8]) -> [UInt8] { PB.varint(UInt64(f << 3 | 2)) + PB.varint(UInt64(b.count)) + b }
    private static func text(_ f: Int, _ s: String) -> [UInt8] { ld(f, ld(1, Array(s.utf8))) }
    private static func f32(_ f: Int, _ x: Float) -> [UInt8] { PB.varint(UInt64(f << 3 | 5)) + withUnsafeBytes(of: x.bitPattern.littleEndian, Array.init) }

    var tst: [UInt8] {
        var phs: [UInt8] = []
        for p in phases {
            var b = Self.text(1, p.name) + Self.vi(2, 1)                    // change: automatic
            b += p.distance
                ? Self.ld(3, Self.vi(1, 2) + Self.f32(3, Float(p.metres)))   // goal: distance (metres)
                : Self.ld(3, Self.vi(1, 1) + Self.ld(2, Self.vi(1, p.seconds / 3600) + Self.vi(2, p.seconds % 3600 / 60) + Self.vi(3, p.seconds % 60) + Self.vi(4, 0)))
            b += p.pace
                ? Self.ld(4, Self.vi(1, 2) + Self.ld(3, Self.vi(1, p.lo) + Self.vi(2, p.hi)))   // pace zones
                : Self.ld(4, Self.vi(1, 1) + Self.ld(2, Self.vi(1, p.lo) + Self.vi(2, p.hi)))   // heart-rate zones
            if let r = p.repeatCount, let j = p.jump { b += Self.vi(5, r) + Self.vi(6, j) }
            phs += Self.ld(1, b)
        }
        let target = Self.vi(1, 2) + Self.ld(2, Self.vi(1, 1)) + Self.ld(4, phs)          // phased, sport 1 = running
        return Self.text(2, name) + Self.text(5, description) + Self.ld(6, target)
    }

    static func idFile(_ id: UInt64, now: Date = Date()) -> [UInt8] {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let dt = ld(1, vi(1, c.year!) + vi(2, c.month!) + vi(3, c.day!)) + ld(2, vi(1, c.hour!) + vi(2, c.minute!) + vi(3, c.second!) + vi(4, 0)) + vi(3, 0)
        return PB.varint(UInt64(1 << 3)) + PB.varint(id) + ld(2, dt) + ld(3, dt)
    }
}

/// Running Plan › Send to watch. Favorite folders /U/0/FAV/<nn>/ must stay numbered without gaps from 00 (the watch
/// stops at the first gap). Folders whose ID.BPB id is ≥ 900000000 were written by LibreFlow and may be replaced or
/// removed; all others (Polar Flow) are never touched. New sessions fill the folders not used by Flow, from 00 up.
@MainActor
final class WatchFavorites: ObservableObject {
    static let ourIds: UInt64 = 900_000_000
    /// One favorite to write: a plan session (new id at write time) or a LibreFlow route favorite that keeps its own
    /// files and only moves to another folder when that is needed to keep FAV without gaps.
    struct Item { var slot: Int; var name: String; var tst: [UInt8]; var idFile: [UInt8]?; var route: Bool; var unchanged = false }
    struct Plan: Equatable { var write: [Item]; var remove: [Int]; var keep: [(slot: Int, name: String)]
        var sessions: Int { write.filter { !$0.route }.count }
        static func == (a: Plan, b: Plan) -> Bool { a.write.map(\.slot) == b.write.map(\.slot) && a.remove == b.remove } }
    enum Phase: Equatable { case idle, reading, ready(Plan), writing(String), done(String), failed(String) }
    @Published var phase: Phase = .idle
    @Published var sessions: [PlanFavorite] = []
    private var listing: [String] = []           // folders as read in the preview step

    private static func slotName(_ i: Int) -> String { String(format: "%02d", i) }
    private static func name(_ tst: [UInt8]) -> String { PBMessage(tst).msg(2)?.first(1)?.data.map { String(decoding: $0, as: UTF8.self) } ?? "?" }
    private var nextId: UInt64 {
        let k = "favIdCounter", n = UInt64(UserDefaults.standard.integer(forKey: k)) + 1
        UserDefaults.standard.set(Int(n), forKey: k); return Self.ourIds + 10 + n
    }

    /// One sync session: read the favorites and keep the session open while the preview is shown; confirm() writes
    /// in the same session, cancel() (or 2 minutes without an answer) ends it without writing.
    private var session: PolarWatch?
    private var expiry: Task<Void, Never>?
    private func close(_ w: PolarWatch) async { try? await w.stopSync(); w.disconnect() }
    private func end() { expiry?.cancel(); expiry = nil; if let w = session { session = nil; Task { await close(w) } } }

    /// Read the favorites on the watch and work out what to write and what to remove.
    func prepare(_ sessions: [PlanFavorite]) async {
        end()
        self.sessions = sessions
        phase = .reading
        let w = PolarWatch()
        do {
            try await w.connect()
            try await w.startSync()
            let folders = try await w.ls("/U/0/FAV/").map { $0.name }.filter { $0.hasSuffix("/") }.compactMap { Int($0.dropLast()) }.sorted()
            var ours: [Int] = [], others: [(Int, String)] = [], routes: [Item] = []
            for f in folders {
                let dir = "/U/0/FAV/\(Self.slotName(f))/"
                let idFile = try? await w.get(dir + "ID.BPB")
                let id = idFile.map { UInt64(PBMessage($0).int(1)) } ?? 0
                let tst = id >= Self.ourIds ? try? await w.get(dir + "TST.BPB") : nil
                if id >= Self.ourIds, let tst, let idFile, PBMessage(tst).msg(6)?.int(1) == 3 {   // a LibreFlow route: keep it
                    routes.append(Item(slot: f, name: Self.name(tst), tst: tst, idFile: idFile, route: true)); ours.append(f)
                } else if id >= Self.ourIds { ours.append(f) }
                else {
                    let name = (try? await w.get(dir + "TST.BPB")).map(Self.name) ?? "?"
                    others.append((f, name))
                }
            }
            listing = folders.map(Self.slotName)
            let otherSlots = Set(others.map { $0.0 }), total = others.count + routes.count + sessions.count
            guard otherSlots.allSatisfy({ $0 < total }) else {
                await close(w)
                phase = .failed("The favorites on the watch are in an order this app cannot fill without moving Polar Flow's favorites. Sync with Polar Flow once, then try again."); return
            }
            let free = (0..<total).filter { !otherSlots.contains($0) }
            let items = routes + sessions.map { Item(slot: 0, name: $0.name, tst: $0.tst, idFile: nil, route: false) }
            let write = zip(free, items).map { slot, it in
                var it = it; it.unchanged = it.route && it.slot == slot; it.slot = slot; return it }
            let remove = ours.filter { $0 >= total }.sorted(by: >)
            session = w
            phase = .ready(Plan(write: write, remove: remove, keep: others.map { (slot: $0.0, name: $0.1) }
                + write.filter(\.unchanged).map { (slot: $0.slot, name: "\($0.name) (route)") }))
            expiry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard let self, !Task.isCancelled, case .ready = self.phase else { return }
                await self.close(w); self.session = nil
                self.phase = .failed("No answer within 2 minutes: the watch session was closed and nothing was written.")
            }
        } catch {
            w.disconnect(); phase = .failed("Could not read the watch: \(error.localizedDescription)")
        }
    }

    func cancel() { end(); phase = .idle }

    /// The user confirmed beforehand: one watch session reads the favorites, writes the sessions, removes LibreFlow
    /// favorites that are no longer needed, and closes. Polar Flow's favorites are never touched.
    func send(_ sessions: [PlanFavorite]) async {
        await prepare(sessions)
        if case .ready = phase { await confirm() }
    }

    /// Write after the user confirmed, in the same session: new/updated favorites first (so there is never a gap),
    /// then remove LibreFlow favorites that are no longer needed.
    func confirm() async {
        guard case .ready(let plan) = phase, let w = session else { return }
        expiry?.cancel(); expiry = nil
        do {
            let todo = plan.write.filter { !$0.unchanged }
            for (n, item) in todo.enumerated() {
                phase = .writing("Writing \(n + 1) of \(todo.count): \(item.name)")
                let dir = "/U/0/FAV/\(Self.slotName(item.slot))/"
                if !listing.contains(Self.slotName(item.slot)) { try await w.put(dir, []) }   // create the folder
                try await w.put(dir + "TST.BPB", item.tst)
                try await w.put(dir + "ID.BPB", item.idFile ?? PlanFavorite.idFile(nextId))
            }
            for slot in plan.remove {
                phase = .writing("Removing old favorite \(Self.slotName(slot))")
                let dir = "/U/0/FAV/\(Self.slotName(slot))/"
                for f in try await w.ls(dir).map({ $0.name }) where !f.hasSuffix("/") { try await w.remove(dir + f) }
                try await w.remove(dir)
            }
            let after = try await w.ls("/U/0/FAV/").map { $0.name }.filter { $0.hasSuffix("/") }.count
            await close(w); session = nil
            phase = .done("\(plan.sessions) training(s) on the watch under Favorites\(plan.remove.isEmpty ? "" : ", \(plan.remove.count) old one(s) removed"). \(after) favorites in all.")
        } catch {
            w.disconnect(); session = nil
            phase = .failed("Stopped: \(error.localizedDescription) Send again to finish; Polar Flow's favorites were not touched.")
        }
    }
}
