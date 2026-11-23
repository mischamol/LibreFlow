import Foundation
import UIKit

/// Downloads every new training (/U/0/<date>/E/<time>/) from the watch, read-only and resumable,
/// like `polar_ble.py --sync all`. Afterwards each new training is decoded for the analysis page.
@MainActor
final class WatchSync: ObservableObject {
    @Published var running = false
    @Published var lines: [String] = []
    @Published var progress: Double = 0
    @Published var lastResult: String?
    /// Called with the ids of newly decoded trainings (the analysis view imports them).
    var onNewTrainings: (([String]) -> Void)?

    private let store = TrainingStore.shared
    private var watch: PolarWatch?
    private var task: Task<Void, Never>?

    func log(_ s: String) {
        lines.append(s)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        // also to Documents/sync-log.txt (for troubleshooting; visible in the Files app, never sent anywhere)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = "\(f.string(from: Date()))  \(s)\n"
        let url = store.root.appendingPathComponent("sync-log.txt")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    func start(fromDate: String = "20230101") {
        guard !running else { return }
        running = true; lines = []; progress = 0; lastResult = nil
        log("— Sync started (app \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")) —")
        UIApplication.shared.isIdleTimerDisabled = true   // keep the screen on: iOS may pause the app when it locks
        task = Task { [weak self] in
            await self?.run(fromDate: fromDate)
            guard let self, !Task.isCancelled else { return }   // after Cancel the state is already reset
            running = false; UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func cancel() {
        task?.cancel()
        watch?.disconnect()
        log("Cancelled.")
        running = false                      // the button goes back to Sync right away
        lastResult = "Sync cancelled."
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func run(fromDate: String) async {
        let w = PolarWatch()
        watch = w
        w.log = { s in Task { @MainActor in self.log(s) } }
        var newIds: [String] = []
        var checked = store.checkedDays()
        do {
            try await w.connect()
            try await w.startSync()
            let today = Self.dayString(Date())
            let days = try await w.ls("/U/0/")
                .map(\.name).filter { $0.hasSuffix("/") && $0.prefix(8).allSatisfy(\.isNumber) }
                .map { String($0.dropLast()) }.filter { $0 >= fromDate }.sorted()
            let todo = days.filter { !checked.contains($0) }
            log("\(days.count) days on the watch, \(todo.count) to check.")
            for (n, day) in todo.enumerated() {
                try Task.checkCancellation()
                progress = Double(n) / Double(max(todo.count, 1))
                var dayComplete = true
                let sub: [String]
                do { sub = try await w.ls("/U/0/\(day)/").map(\.name) } catch PolarError.protocolError { continue }
                if sub.contains("E/") {
                    for t in try await w.ls("/U/0/\(day)/E/").map(\.name) where t.hasSuffix("/") {
                        let time = String(t.dropLast()), id = "\(day)_\(time)"
                        if store.isComplete(id) { continue }
                        do {
                            let bytes = try await download("/U/0/\(day)/E/\(time)/", id: id, rel: "", depth: 3, w: w)
                            store.markComplete(id)
                            newIds.append(id)
                            log("Downloaded \(Self.pretty(id)) (\(bytes / 1024) kB).")
                        } catch PolarError.protocolError(let c) {
                            log("\(Self.pretty(id)): watch error \(c), skipped (retried next time).")
                            dayComplete = false
                        }
                    }
                }
                if dayComplete && day < today {
                    checked.insert(day)
                    if n % 25 == 0 { store.saveCheckedDays(checked) }
                }
            }
            store.saveCheckedDays(checked)
            try await w.stopSync()
            w.disconnect()
            progress = 1
        } catch {
            store.saveCheckedDays(checked)
            w.disconnect()
            log("Stopped: \(error.localizedDescription) Starting again continues where it stopped.")
        }
        // decode what came in, plus anything downloaded earlier but not decoded yet (e.g. after an interruption)
        var decoded: [String] = []
        for id in store.watchTrainingIds().reversed() where !store.hasSession(id) {
            if let t = store.decoded(id), store.writeSession(t) { decoded.append(id) }
            else if newIds.contains(id) { log("\(Self.pretty(id)): incomplete training on the watch, not added to the analysis.") }
        }
        if !Task.isCancelled || !decoded.isEmpty {   // after Cancel keep "Sync cancelled." unless something was still added
            lastResult = newIds.isEmpty && decoded.isEmpty ? "No new trainings." : "\(newIds.count) new training(s), \(decoded.count) added to the analysis."
        }
        log(lastResult ?? "Sync cancelled.")
        if !decoded.isEmpty { onNewTrainings?(decoded) }
        watch = nil
    }

    private func download(_ path: String, id: String, rel: String, depth: Int, w: PolarWatch) async throws -> Int {
        var total = 0
        for (name, size) in try await w.ls(path) {
            try Task.checkCancellation()
            if name.hasSuffix("/") {
                if depth > 0 { total += try await download(path + name, id: id, rel: rel + name, depth: depth - 1, w: w) }
                continue
            }
            if store.rawSize(id: id, relativePath: rel + name) == size { continue }
            let data = try await w.get(path + name, timeout: 300)
            try store.writeRaw(data, id: id, relativePath: rel + name)
            total += data.count
        }
        return total
    }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
    /// "20250105_081500" -> "5 Jan 2025 08:15"
    static func pretty(_ id: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: id) else { return id }
        let o = DateFormatter(); o.locale = Locale(identifier: "en_GB"); o.dateFormat = "d MMM yyyy HH:mm"
        return o.string(from: d)
    }
}
