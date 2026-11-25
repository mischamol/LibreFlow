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
    var tst: [UInt8] {
        var phs: [UInt8] = []
        for p in phases {
            var b = PB.text(1, p.name) + PB.vi(2, 1)                    // change: automatic
            b += p.distance
                ? PB.ld(3, PB.vi(1, 2) + PB.f32(3, Double(p.metres)))   // goal: distance (metres)
                : PB.ld(3, PB.vi(1, 1) + PB.ld(2, PB.vi(1, p.seconds / 3600) + PB.vi(2, p.seconds % 3600 / 60) + PB.vi(3, p.seconds % 60) + PB.vi(4, 0)))
            b += p.pace
                ? PB.ld(4, PB.vi(1, 2) + PB.ld(3, PB.vi(1, p.lo) + PB.vi(2, p.hi)))   // pace zones
                : PB.ld(4, PB.vi(1, 1) + PB.ld(2, PB.vi(1, p.lo) + PB.vi(2, p.hi)))   // heart-rate zones
            if let r = p.repeatCount, let j = p.jump { b += PB.vi(5, r) + PB.vi(6, j) }
            phs += PB.ld(1, b)
        }
        let target = PB.vi(1, 2) + PB.ld(2, PB.vi(1, 1)) + PB.ld(4, phs)          // phased, sport 1 = running
        return PB.text(2, name) + PB.text(5, description) + PB.ld(6, target)
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
    private var listing: [Int] = []           // folders as read in the preview step

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
            let folders = try await w.folderNumbers("/U/0/FAV/")
            var ours: [Int] = [], others: [(Int, String)] = [], routes: [Item] = []
            for f in folders {
                let dir = PolarWatch.favDir(f)
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
            listing = folders
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
                let dir = PolarWatch.favDir(item.slot)
                if !listing.contains(item.slot) { try await w.put(dir, []) }   // create the folder
                try await w.put(dir + "TST.BPB", item.tst)
                try await w.put(dir + "ID.BPB", item.idFile ?? PB.favoriteIdFile(nextId))
            }
            for slot in plan.remove {
                phase = .writing("Removing an old LibreFlow favorite")
                try await w.removeFolder(PolarWatch.favDir(slot))
            }
            let after = try await w.folderNumbers("/U/0/FAV/").count
            await close(w); session = nil
            phase = .done("\(plan.sessions) training(s) on the watch under Favorites\(plan.remove.isEmpty ? "" : ", \(plan.remove.count) old one(s) removed"). \(after) favorites in all.")
        } catch {
            w.disconnect(); session = nil
            phase = .failed("Stopped: \(error.localizedDescription) Send again to finish; Polar Flow's favorites were not touched.")
        }
    }
}
