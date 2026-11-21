import Foundation

/// Builds a GPX 1.1 file from a decoded watch training: route, time and elevation, plus cadence and – only when
/// `includeHeartRate` is true – heart rate in the widely supported Garmin TrackPointExtension.
enum GPXWriter {
    static func gpx(for t: DecodedTraining, includeHeartRate: Bool, name: String? = nil) -> String? {
        guard let start = t.startDate, !t.route.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let type: String
        switch t.sport {
        case let s where s.contains("RUN") || s.contains("JOG"): type = "running"
        case let s where s.contains("CYCL") || s.contains("BIK"): type = "cycling"
        case let s where s.contains("WALK"): type = "walking"
        case let s where s.contains("HIK"): type = "hiking"
        default: type = "other"
        }
        // per-second series by elapsed second
        func at<T>(_ a: [T], _ sec: Double) -> T? {
            let i = Int((sec / max(t.intervalSec, 0.001)).rounded())
            return i >= 0 && i < a.count ? a[i] : nil
        }
        var pts = ""
        pts.reserveCapacity(t.route.count * 200)
        for p in t.route {
            var x = String(format: "<trkpt lat=\"%.7f\" lon=\"%.7f\">", p.lat, p.lon)
            if let e = at(t.altitude, p.t) { x += String(format: "<ele>%.1f</ele>", e) }
            x += "<time>\(iso.string(from: start.addingTimeInterval(p.t)))</time>"
            var ext = ""
            if includeHeartRate, let h = at(t.hr, p.t), h > 0 { ext += "<gpxtpx:hr>\(h)</gpxtpx:hr>" }
            if let c = at(t.cadence, p.t), c > 0 { ext += "<gpxtpx:cad>\(c / 2)</gpxtpx:cad>" }   // per leg, as Garmin does
            if !ext.isEmpty { x += "<extensions><gpxtpx:TrackPointExtension>\(ext)</gpxtpx:TrackPointExtension></extensions>" }
            pts += x + "</trkpt>\n"
        }
        let title = (name ?? "Activity").replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="LibreFlow" xmlns="http://www.topografix.com/GPX/1/1" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
        <metadata><time>\(iso.string(from: start))</time></metadata>
        <trk><name>\(title)</name><type>\(type)</type><trkseg>
        \(pts)</trkseg></trk>
        </gpx>

        """
    }
}
