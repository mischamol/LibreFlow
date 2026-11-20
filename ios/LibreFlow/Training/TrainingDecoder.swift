import Foundation

/// A GPS point of a training (seconds since start).
struct RoutePoint { let t: Double; let lat: Double; let lon: Double }

/// Decoded watch training: the summary + 1 s series, in the same JSON shape as polar_ble.py's
/// training-session.json (so the analysis page reads it unchanged), plus the GPS route kept apart.
struct DecodedTraining {
    let id: String                 // "YYYYMMDD_HHMMSS" (watch folder)
    let startLocal: String         // "2026-11-19T19:33:03.394"
    let tzOffsetMin: Int
    let durationSec: Double
    let distanceM: Double
    let kcal: Int?
    let ascentM: Double?
    let sport: String
    let hrAvg: Int?, hrMax: Int?
    let cadAvg: Int?, cadMax: Int?            // steps per minute
    let runningIndex: Int?                     // Polar running index computed by the watch
    let speedAvg: Double?, speedMax: Double?   // km/h, as computed by the watch (STATS field 2)
    let intervalSec: Double
    let hr: [Int], cadence: [Int]               // cadence in steps per minute
    let altitude: [Double], speed: [Double], distance: [Double]   // m, km/h, m
    let route: [RoutePoint]

    /// Start as an absolute moment (the watch stores local time + offset).
    var startDate: Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: tzOffsetMin * 60)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f.date(from: startLocal)
    }

    /// training-session JSON for the analysis page (no GPS route: it is not needed there).
    func sessionJSON() -> [String: Any] {
        var ex: [String: Any] = [:]
        if let a = cadAvg { ex["cadence"] = ["avg": a, "max": cadMax ?? a, "unit": "spm"] }
        if let r = runningIndex { ex["runningIndex"] = r }
        if let m = speedMax, m > 0 { ex["speed"] = ["avg": ((speedAvg ?? 0) * 100).rounded() / 100, "max": (m * 100).rounded() / 100] }
        if !hr.isEmpty || !speed.isEmpty {
            ex["samples"] = ["intervalSec": intervalSec, "heartRate": hr, "cadence": cadence,
                             "altitude": altitude.map { ($0 * 10).rounded() / 10 },
                             "speed": speed.map { ($0 * 100).rounded() / 100 },
                             "distance": distance.map { ($0 * 10).rounded() / 10 }]
        }
        var j: [String: Any] = ["startTime": startLocal, "timeZoneOffset": tzOffsetMin,
                                "duration": String(format: "PT%.3fS", durationSec), "distance": distanceM,
                                "sport": sport, "source": "LibreFlow iPhone app (directly from watch)",
                                "watchId": id, "exercises": [ex]]
        if let v = kcal { j["kiloCalories"] = v }
        if let v = ascentM { j["ascent"] = v }
        if let v = hrAvg { j["averageHeartRate"] = v }
        if let v = hrMax { j["maximumHeartRate"] = v }
        return j
    }
}

enum TrainingDecoder {
    /// names as defined by the watch itself (/SYS/SPORT/<id>/SPORT.BPB)
    static let sports = [1: "RUNNING", 2: "CYCLING", 3: "WALKING", 5: "MOUNTAIN_BIKING", 7: "DOWNHILL_SKIING", 11: "HIKING",
                         15: "STRENGTH_TRAINING", 16: "OTHER_OUTDOOR", 23: "SWIMMING", 27: "TRAIL_RUNNING", 64: "BODY_AND_MIND",
                         82: "MULTISPORT", 83: "OTHER_INDOOR", 126: "CORE", 127: "MOBILITY_STATIC"]

    static func read(_ url: URL) -> [UInt8]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return Gzip.decompressIfNeeded([UInt8](d))
    }

    static func duration(_ m: PBMessage?) -> Double {
        guard let m else { return 0 }
        return Double(m.int(1) * 3600 + m.int(2) * 60 + m.int(3)) + Double(m.int(4)) / 1000
    }

    /// Decode a downloaded watch folder (…/<id>/ with 00/BASE.BPB etc.). Nil when BASE is missing.
    static func decode(dir: URL, id: String) -> DecodedTraining? {
        let ex = dir.appendingPathComponent("00")
        guard let baseBytes = read(ex.appendingPathComponent("BASE.BPB")) else { return nil }
        let base = PBMessage(baseBytes)
        let stats = read(ex.appendingPathComponent("STATS.BPB")).map { PBMessage($0) }
        let samples = read(ex.appendingPathComponent("SAMPLES.GZB")).map { PBMessage($0) }
        let route = read(ex.appendingPathComponent("ROUTE.GZB")).map { PBMessage($0) }

        guard let lt = base.msg(1), let date = lt.msg(1) else { return nil }
        let time = lt.msg(2)
        let start = String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d", date.int(1), date.int(2), date.int(3),
                           time?.int(1) ?? 0, time?.int(2) ?? 0, time?.int(3) ?? 0, time?.int(4) ?? 0)
        let sportId = base.msg(3)?.int(1) ?? 0
        let hrStats = stats?.msg(1), cad = stats?.msg(3)
        let sportName = sports[sportId] ?? "SPORT_\(sportId)"

        var interval = 1.0, hr: [Int] = [], cadence: [Int] = [], alt: [Double] = [], spd: [Double] = [], dist: [Double] = []
        if let s = samples {
            interval = max(duration(s.msg(1)), 0) == 0 ? 1 : duration(s.msg(1))
            hr = s.varints(2)
            cadence = s.varints(4).map { $0 * 2 }        // per leg -> steps per minute
            alt = s.floats(6).map(Double.init)
            spd = s.floats(9).map(Double.init)
            dist = s.floats(11).map(Double.init)
        }
        var points: [RoutePoint] = []
        if let r = route {
            let t = r.varints(1), lat = r.doubles(2), lon = r.doubles(3)
            for i in 0..<min(lat.count, lon.count) {
                points.append(RoutePoint(t: i < t.count ? Double(t[i]) / 1000 : Double(i), lat: lat[i], lon: lon[i]))
            }
        }
        return DecodedTraining(
            id: id, startLocal: start, tzOffsetMin: lt.int(4), durationSec: duration(base.msg(2)),
            distanceM: Double(base.float(4) ?? 0), kcal: base.optInt(5), ascentM: base.float(11).map(Double.init),
            sport: sportName, hrAvg: hrStats?.optInt(2), hrMax: hrStats?.optInt(3),
            cadAvg: cad?.optInt(1).map { $0 * 2 }, cadMax: cad?.optInt(2).map { $0 * 2 },
            runningIndex: base.msg(9)?.optInt(1),   // BASE field 9 > 1
            speedAvg: stats?.msg(2)?.float(1).map(Double.init), speedMax: stats?.msg(2)?.float(2).map(Double.init),
            intervalSec: interval, hr: hr, cadence: cadence, altitude: alt, speed: spd, distance: dist, route: points)
    }
}
