import Foundation

/// Everything the app keeps, in its own Documents folder (visible in the Files app, never uploaded):
///   watch/<YYYYMMDD_HHMMSS>/…   raw files as downloaded from the watch (+ .complete marker)
///   watch/index.json            days that are fully checked (so a sync only looks at new days)
///   sessions/<id>.json          decoded training-session JSON for the analysis page
///   analysis-store.json         the analysis page's own stored data
///   imported.json               session ids already handed to the analysis page
final class TrainingStore {
    static let shared = TrainingStore()
    let root: URL
    var watchDir: URL { root.appendingPathComponent("watch") }
    var sessionsDir: URL { root.appendingPathComponent("sessions") }
    /// full per-second data + GPS route per activity, written by the analysis page (raw/<key>.json)
    var rawDir: URL { root.appendingPathComponent("raw") }
    var analysisStoreURL: URL { root.appendingPathComponent("analysis-store.json") }
    private var importedURL: URL { root.appendingPathComponent("imported.json") }
    private var indexURL: URL { watchDir.appendingPathComponent("index.json") }
    private let fm = FileManager.default

    init(root: URL? = nil) {
        self.root = root ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: watchDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    // MARK: checked days
    func checkedDays() -> Set<String> {
        guard let d = try? Data(contentsOf: indexURL),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let days = j["checkedDays"] as? [String] else { return [] }
        return Set(days)
    }
    func saveCheckedDays(_ days: Set<String>) {
        let d = try? JSONSerialization.data(withJSONObject: ["checkedDays": days.sorted()])
        try? d?.write(to: indexURL, options: .atomic)
    }

    // MARK: raw trainings
    func trainingDir(_ id: String) -> URL { watchDir.appendingPathComponent(id) }
    func isComplete(_ id: String) -> Bool { fm.fileExists(atPath: trainingDir(id).appendingPathComponent(".complete").path) }
    func markComplete(_ id: String) { fm.createFile(atPath: trainingDir(id).appendingPathComponent(".complete").path, contents: Data()) }

    func writeRaw(_ data: [UInt8], id: String, relativePath: String) throws {
        let url = trainingDir(id).appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(data).write(to: url, options: .atomic)
    }
    func rawSize(id: String, relativePath: String) -> Int? {
        (try? fm.attributesOfItem(atPath: trainingDir(id).appendingPathComponent(relativePath).path))?[.size] as? Int
    }

    /// Ids of all downloaded watch trainings, newest first.
    func watchTrainingIds() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: watchDir.path)) ?? [])
            .filter { $0.count == 15 && $0.contains("_") && isComplete($0) }
            .sorted(by: >)
    }

    func decoded(_ id: String) -> DecodedTraining? { TrainingDecoder.decode(dir: trainingDir(id), id: id) }

    // MARK: sessions for the analysis page
    func hasSession(_ id: String) -> Bool { fm.fileExists(atPath: sessionsDir.appendingPathComponent("\(id).json").path) }

    @discardableResult
    func writeSession(_ t: DecodedTraining) -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: t.sessionJSON()) else { return false }
        return (try? d.write(to: sessionsDir.appendingPathComponent("\(t.id).json"), options: .atomic)) != nil
    }

    /// Bump when the decoder learns new fields: watch trainings are then decoded again from the raw files on the
    /// phone and handed to the analysis page once more (the newest import wins there). 2 = running index + max speed.
    static let sessionFormat = 3   // 3 = GPS route included (for the route view and the raw data)
    func upgradeSessionsIfNeeded() {
        let key = "sessionFormat"
        guard UserDefaults.standard.integer(forKey: key) < Self.sessionFormat else { return }
        var redone: [String] = []
        for id in watchTrainingIds() where hasSession(id) {
            if let t = decoded(id), writeSession(t) { redone.append(id) }
        }
        forgetImported(redone)
        UserDefaults.standard.set(Self.sessionFormat, forKey: key)
    }

    func importedIds() -> Set<String> {
        guard let d = try? Data(contentsOf: importedURL), let a = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
        return Set(a)
    }
    func markImported(_ ids: [String]) {
        let all = importedIds().union(ids)
        try? JSONSerialization.data(withJSONObject: all.sorted()).write(to: importedURL, options: .atomic)
    }
    /// Hand these sessions to the analysis page again at the next import.
    func forgetImported(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let keep = importedIds().subtracting(ids)
        try? JSONSerialization.data(withJSONObject: keep.sorted()).write(to: importedURL, options: .atomic)
    }
    /// Session JSON texts the analysis page has not seen yet.
    func pendingSessions() -> [(id: String, json: String)] {
        let done = importedIds()
        return ((try? fm.contentsOfDirectory(atPath: sessionsDir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .filter { !done.contains($0) }
            .sorted()
            .compactMap { id in
                (try? String(contentsOf: sessionsDir.appendingPathComponent("\(id).json"), encoding: .utf8)).map { (id, $0) }
            }
    }

    // MARK: raw data per activity
    private func rawURL(_ key: String) -> URL? {
        guard !key.isEmpty, key.allSatisfy({ $0.isNumber || $0 == "-" }) else { return nil }   // keys are numbers
        return rawDir.appendingPathComponent("\(key).json")
    }
    func putRaw(_ key: String, _ text: String) {
        guard let u = rawURL(key) else { return }
        try? fm.createDirectory(at: rawDir, withIntermediateDirectories: true)
        try? text.write(to: u, atomically: true, encoding: .utf8)
    }
    func getRaw(_ key: String) -> String? { rawURL(key).flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
    func deleteRaw(_ key: String) { if let u = rawURL(key) { try? fm.removeItem(at: u) } }
    func clearRaw() { try? fm.removeItem(at: rawDir) }

    /// Backup ZIP: libreflow-backup.json (summary from the page) + raw/<key>.json for every activity.
    func makeBackupZip(name: String, summary: String) -> URL? {
        let tmp = fm.temporaryDirectory.appendingPathComponent(name)
        try? fm.removeItem(at: tmp)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            try summary.write(to: tmp.appendingPathComponent("libreflow-backup.json"), atomically: true, encoding: .utf8)
            if fm.fileExists(atPath: rawDir.path) { try fm.copyItem(at: rawDir, to: tmp.appendingPathComponent("raw")) }
        } catch { return nil }
        var result: URL?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: tmp, options: .forUploading, error: &err) { zip in   // iOS zips a folder for "uploading"
            let dest = fm.temporaryDirectory.appendingPathComponent("\(name).zip")
            try? fm.removeItem(at: dest)
            if (try? fm.copyItem(at: zip, to: dest)) != nil { result = dest }
        }
        try? fm.removeItem(at: tmp)
        return result
    }

    // MARK: analysis page storage
    func loadAnalysisStore() -> String? { try? String(contentsOf: analysisStoreURL, encoding: .utf8) }
    func saveAnalysisStore(_ text: String) {
        if text.isEmpty {
            try? fm.removeItem(at: analysisStoreURL)
            try? fm.removeItem(at: importedURL)       // page was cleared: hand the watch sessions over again
        } else {
            try? text.write(to: analysisStoreURL, atomically: true, encoding: .utf8)
        }
    }

    /// Remove everything the app stored.
    func deleteAll() {
        for u in [watchDir, sessionsDir, rawDir, analysisStoreURL, importedURL] { try? fm.removeItem(at: u) }
        try? fm.createDirectory(at: watchDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }
}
