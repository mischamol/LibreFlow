import Foundation

/// Settings › Training zones › Send zones to watch. Reads the running sport profile from the watch, shows the
/// current and the new zones, and only after the user confirms writes the profile back with nothing but the zone
/// limits changed; then reads it back to check. The first profile ever read is kept as a backup ("Restore").
@MainActor
final class WatchZones: ObservableObject {
    enum Phase: Equatable {
        case idle, reading, writing
        case preview(current: ProfileZones, new: ProfileZones, restore: Bool)
        case done(String), failed(String)
    }
    @Published var phase: Phase = .idle

    static let path = "/U/0/SPROF/0/PROFILE.BPB"
    private var file: [UInt8]?                 // the profile as read in the preview step
    private var pendingNew: [UInt8]?            // what will be written
    private let dir = TrainingStore.shared.root.appendingPathComponent("zones-backup")
    private var originalURL: URL { dir.appendingPathComponent("PROFILE-original.BPB") }
    private var previousURL: URL { dir.appendingPathComponent("PROFILE-previous.BPB") }
    var hasBackup: Bool { FileManager.default.fileExists(atPath: originalURL.path) }

    /// Read the profile and prepare the app's zones (zone 1 keeps its lower and zone 5 its upper limit from the watch).
    func prepare(hr: [Int], pace: [Int]) async {
        guard hr.count == 6, pace.count == 5 else { phase = .failed("No zones to send."); return }
        await read { cur in
            let speed: [Float] = [cur.speed[0].lowerBound] + pace[1...4].map { 3600 / Float($0) } + [cur.speed[4].upperBound]
            let lows = [cur.hr[0].lowerBound] + Array(hr[1...4]), highs = Array(hr[1...5])
            return ProfileZones(hr: zip(lows, highs).map { $0...$1 }, speed: zip(speed, speed.dropFirst()).map { $0...$1 })
        }
    }

    /// Read the profile and prepare the zones of the backup made before the first change.
    func prepareRestore() async {
        guard let b = try? Data(contentsOf: originalURL), let z = ProfileZones.read([UInt8](b)) else { phase = .failed("No backup found."); return }
        await read(restore: true) { _ in z }
    }

    private func read(restore: Bool = false, make: (ProfileZones) -> ProfileZones) async {
        phase = .reading
        let w = PolarWatch()
        do {
            try await w.connect()
            try await w.startSync()
            let b = try await w.get(Self.path)
            try? await w.stopSync()
            w.disconnect()
            guard ProfileZones.sport(b) == 1, let cur = ProfileZones.read(b) else { phase = .failed("The running profile on the watch looks different than expected; nothing was changed."); return }
            let wanted = make(cur)
            let out = restore ? (try? Data(contentsOf: originalURL)).map { [UInt8]($0) } : try? wanted.replacing(in: b)
            guard let out, let check = ProfileZones.read(out) else { phase = .failed("Could not build the new profile; nothing was changed."); return }
            if out == b { phase = .done("The watch already has these zones."); return }
            file = b; pendingNew = out
            phase = .preview(current: cur, new: check, restore: restore)
        } catch {
            w.disconnect()
            phase = .failed("Could not read the watch: \(error.localizedDescription)")
        }
    }

    func cancel() { file = nil; pendingNew = nil; phase = .idle }

    /// Write after the user confirmed. Re-reads first and stops if the profile changed in between.
    func confirm() async {
        guard let file, let out = pendingNew else { return }
        phase = .writing
        let w = PolarWatch()
        do {
            try await w.connect()
            try await w.startSync()
            let now = try await w.get(Self.path)
            guard now == file else {
                try? await w.stopSync(); w.disconnect()
                phase = .failed("The profile on the watch changed in the meantime; nothing was written. Try again."); return
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !hasBackup { try Data(file).write(to: originalURL) }      // the zones as they were before LibreFlow changed them
            try Data(file).write(to: previousURL)
            try await w.put(Self.path, out)
            let back = try await w.get(Self.path)
            try? await w.stopSync()
            w.disconnect()
            self.file = nil; pendingNew = nil
            phase = back == out ? .done("Zones written to the watch and checked. New trainings use them from now on.")
                                : .failed("Written, but reading back gave a different file. Use Restore original zones to be safe.")
        } catch {
            w.disconnect()
            phase = .failed("Writing failed: \(error.localizedDescription) Restore original zones puts the backup back.")
        }
    }
}
