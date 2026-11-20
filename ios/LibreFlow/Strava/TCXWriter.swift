import Foundation

/// Builds a Garmin TCX file (accepted by Strava) from a decoded watch training.
/// Heart rate is only written when `includeHeartRate` is true.
enum TCXWriter {
    static func tcx(for t: DecodedTraining, includeHeartRate: Bool) -> String? {
        guard let start = t.startDate else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let sport: String
        switch t.sport {
        case let s where s.contains("RUN") || s.contains("JOG"): sport = "Running"
        case let s where s.contains("CYCL") || s.contains("BIK"): sport = "Biking"
        default: sport = "Other"
        }
        let n = max(t.hr.count, t.speed.count, t.distance.count)
        // route sample nearest to each second
        var routeAt: [Int: RoutePoint] = [:]
        for p in t.route { routeAt[Int(p.t.rounded())] = p }
        var lastPos: RoutePoint? = nil

        var tp = ""
        tp.reserveCapacity(n * 220)
        for i in 0..<n {
            let sec = Double(i) * t.intervalSec
            var x = "<Trackpoint><Time>\(iso.string(from: start.addingTimeInterval(sec)))</Time>"
            if let p = routeAt[Int(sec.rounded())] { lastPos = p }
            if let p = lastPos, routeAt[Int(sec.rounded())] != nil {
                x += String(format: "<Position><LatitudeDegrees>%.7f</LatitudeDegrees><LongitudeDegrees>%.7f</LongitudeDegrees></Position>", p.lat, p.lon)
            }
            if i < t.altitude.count { x += String(format: "<AltitudeMeters>%.1f</AltitudeMeters>", t.altitude[i]) }
            if i < t.distance.count { x += String(format: "<DistanceMeters>%.1f</DistanceMeters>", t.distance[i]) }
            if includeHeartRate, i < t.hr.count, t.hr[i] > 0 { x += "<HeartRateBpm><Value>\(t.hr[i])</Value></HeartRateBpm>" }
            var ext = ""
            if i < t.speed.count { ext += String(format: "<ns3:Speed>%.3f</ns3:Speed>", t.speed[i] / 3.6) }
            if i < t.cadence.count, t.cadence[i] > 0 { ext += "<ns3:RunCadence>\(t.cadence[i] / 2)</ns3:RunCadence>" }   // TCX: per leg
            if !ext.isEmpty { x += "<Extensions><ns3:TPX>\(ext)</ns3:TPX></Extensions>" }
            tp += x + "</Trackpoint>\n"
        }
        var lap = "<TotalTimeSeconds>\(String(format: "%.1f", t.durationSec))</TotalTimeSeconds>"
        lap += "<DistanceMeters>\(String(format: "%.1f", t.distanceM))</DistanceMeters>"
        lap += "<Calories>\(t.kcal ?? 0)</Calories>"
        if includeHeartRate, let a = t.hrAvg, let m = t.hrMax {
            lap += "<AverageHeartRateBpm><Value>\(a)</Value></AverageHeartRateBpm><MaximumHeartRateBpm><Value>\(m)</Value></MaximumHeartRateBpm>"
        }
        lap += "<Intensity>Active</Intensity><TriggerMethod>Manual</TriggerMethod>"
        let id = iso.string(from: start)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2">
        <Activities><Activity Sport="\(sport)"><Id>\(id)</Id>
        <Lap StartTime="\(id)">\(lap)<Track>
        \(tp)</Track></Lap>
        <Creator xsi:type="Device_t" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><Name>Polar Grit X</Name></Creator>
        </Activity></Activities></TrainingCenterDatabase>

        """
    }
}
