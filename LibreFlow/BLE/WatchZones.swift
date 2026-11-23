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

    /// The zones the app would put on the watch (zone 1 lower and zone 5 upper limits are kept from the watch).
    static func wanted(hr: [Int], pace: [Int], keeping cur: ProfileZones) -> ProfileZones {
        let speed: [Float] = [cur.speed[0].lowerBound] + pace[1...4].map { 3600 / Float($0) } + [cur.speed[4].upperBound]
        let lows = [cur.hr[0].lowerBound] + Array(hr[1...4]), highs = Array(hr[1...5])
        return ProfileZones(hr: zip(lows, highs).map { $0...$1 }, speed: zip(speed, speed.dropFirst()).map { $0...$1 })
    }

    /// The user already confirmed (before connecting): one watch session reads the running profile, writes only the
    /// zone limits, reads it back and closes. No second confirmation, no second sync on the watch.
    func send(hr: [Int], pace: [Int]) async {
        guard hr.count == 6, pace.count == 5 else { phase = .failed("No zones to send."); return }
        await run({ cur, _ in Self.wanted(hr: hr, pace: pace, keeping: cur) })
    }

    /// Same, putting back the profile saved before LibreFlow first changed the zones.
    func restore() async {
        guard let b = try? Data(contentsOf: originalURL) else { phase = .failed("No backup found."); return }
        await run({ _, _ in nil }, restoreFile: [UInt8](b))
    }

    private func run(_ make: (ProfileZones, [UInt8]) throws -> ProfileZones?, restoreFile: [UInt8]? = nil) async {
        phase = .writing
        let w = PolarWatch()
        do {
            try await w.connect()
            try await w.startSync()
            let b = try await w.get(Self.path)
            guard ProfileZones.sport(b) == 1, let cur = ProfileZones.read(b) else {
                await close(w); phase = .failed("The running profile on the watch looks different than expected; nothing was changed."); return
            }
            let out: [UInt8]
            if let restoreFile { out = restoreFile }
            else if let z = try make(cur, b) { out = try z.replacing(in: b) }
            else { await close(w); return }
            guard ProfileZones.read(out) != nil else { await close(w); phase = .failed("Could not build the new profile; nothing was changed."); return }
            if out == b { await close(w); phase = .done("The watch already had these zones."); return }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !hasBackup { try Data(b).write(to: originalURL) }      // the zones as they were before LibreFlow changed them
            try Data(b).write(to: previousURL)
            try await w.put(Self.path, out)
            let back = try await w.get(Self.path)
            await close(w)
            phase = back == out ? .done(restoreFile == nil ? "Zones written to the watch and checked. New trainings use them from now on." : "Original zones put back on the watch and checked.")
                                : .failed("Written, but reading back gave a different file. Use Restore original zones to be safe.")
        } catch {
            w.disconnect()
            phase = .failed("Stopped: \(error.localizedDescription) Nothing else was changed; try again.")
        }
    }

    private func close(_ w: PolarWatch) async { try? await w.stopSync(); w.disconnect() }
}
