import SwiftUI
import MapKit

/// Preview of exactly what would be exported, with an explicit heart-rate choice (off by default).
/// toStrava = false: save the run as a TCX file. toStrava = true: upload directly via the Strava API (paid subscription).
struct StravaExportView: View {
    let trainingId: String
    var toStrava = false
    @EnvironmentObject var strava: StravaClient
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var training: DecodedTraining?
    @State private var includeHR = false
    @State private var name = ""
    @State private var busy = false
    @State private var message: String?
    @State private var activityId: Int?
    @State private var share: AppModel.ShareItem?

    var body: some View {
        NavigationStack {
            Form {
                if let t = training {
                    Section("Training") {
                        LabeledContent("Date", value: WatchSync.pretty(trainingId))
                        LabeledContent("Sport", value: t.sport.replacingOccurrences(of: "_", with: " ").capitalized)
                        LabeledContent("Distance", value: String(format: "%.2f km", t.distanceM / 1000))
                        LabeledContent("Duration", value: Self.hms(t.durationSec))
                        if t.distanceM > 0 { LabeledContent("Pace", value: Self.pace(t.durationSec / (t.distanceM / 1000)) + " /km") }
                    }
                    if !t.route.isEmpty {
                        Section {
                            Map(initialPosition: .automatic) {
                                MapPolyline(coordinates: t.route.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                                    .stroke(.orange, lineWidth: 3)
                            }
                            .frame(height: 200)
                            .listRowInsets(EdgeInsets())
                        } footer: { Text(toStrava ? "This route, including where it starts and ends, becomes visible on Strava according to your Strava privacy settings." : "The file contains this route, including where it starts and ends.") }
                    }
                    Section {
                        if toStrava { TextField("Activity name", text: $name) }
                        Toggle("Include heart rate", isOn: $includeHR)
                    } header: { Text(toStrava ? "What is sent" : "What is in the file") } footer: {
                        Text((toStrava ? "Sent" : "Included") + ": GPS route, time, distance, altitude, speed and cadence" + (includeHR ? ", and heart rate (average, maximum and per second)." : ". Heart rate is left out."))
                    }
                    if !toStrava {
                        Section {
                            Button { shareFile(t) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                        } footer: {
                            Text(t.route.isEmpty ? "This run has no GPS route, so it is saved as a TCX file (Files, iCloud Drive, AirDrop…)." : "Saves the run as a GPX file (Files, iCloud Drive, AirDrop…): route, time, elevation and cadence, plus heart rate if ticked. Upload it yourself, for example at strava.com › + › Upload activity › File (free account; on an iPhone, Safari needs \"Request Desktop Website\" for that page), or open it in any app that reads GPX.")
                        }
                    } else {
                    Section {
                        if strava.isConnected {
                            Button {
                                Task { await upload(t) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Upload to Strava")
                                        Text("Via the Strava API (paid Strava subscription)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if busy { Spacer(); ProgressView() }
                                }
                            }
                            .disabled(busy || name.isEmpty)
                        } else {
                            Text("Connect Strava first under Settings › Strava › Direct upload (paid Strava subscription).").foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Nothing is sent until you tap Upload.")
                    }
                    }
                    if let message {
                        Section {
                            Text(message)
                            if let a = activityId, let url = URL(string: "https://www.strava.com/activities/\(a)") { Link("Open in Strava", destination: url) }
                        }
                    }
                } else {
                    Text("This training has no summary on the watch (it was not saved properly) and cannot be exported.")
                }
            }
            .navigationTitle(toStrava ? "To Strava" : "Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(item: $share) { s in ShareSheet(items: [s.url]) }
            .onAppear {
                training = model.store.decoded(trainingId)
                if name.isEmpty, let t = training { name = Self.defaultName(t) }
            }
        }
    }

    private func upload(_ t: DecodedTraining) async {
        guard let tcx = TCXWriter.tcx(for: t, includeHeartRate: includeHR) else { message = "Could not build the file."; return }
        busy = true; message = "Uploading…"; activityId = nil
        defer { busy = false }
        do {
            let id = try await strava.upload(tcx: tcx, name: name, externalId: "libreflow-\(trainingId)")
            activityId = id
            message = "Uploaded" + (includeHR ? " with heart rate." : " without heart rate.")
        } catch {
            message = error.localizedDescription
        }
    }

    /// GPX (route, time, elevation, cadence, heart rate only if ticked); TCX for runs without GPS, where GPX is empty.
    private func shareFile(_ t: DecodedTraining) {
        let base = "\(trainingId)\(includeHR ? "" : "-no-hr")"
        let (text, ext): (String?, String) = t.route.isEmpty
            ? (TCXWriter.tcx(for: t, includeHeartRate: includeHR), "tcx")
            : (GPXWriter.gpx(for: t, includeHeartRate: includeHR, name: Self.defaultName(t)), "gpx")
        guard let text else { message = "Could not build the file."; return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(base).\(ext)")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        share = .init(url: url)
    }

    static func defaultName(_ t: DecodedTraining) -> String {
        let h = Int(t.startLocal.dropFirst(11).prefix(2)) ?? 12
        let part = h < 12 ? "Morning" : h < 18 ? "Afternoon" : "Evening"
        let what = t.sport.contains("RUN") ? "Run" : t.sport.contains("CYCL") || t.sport.contains("BIK") ? "Ride" : t.sport.contains("WALK") ? "Walk" : "Activity"
        return "\(part) \(what)"
    }
    static func hms(_ s: Double) -> String { let x = Int(s); return String(format: "%d:%02d:%02d", x / 3600, x % 3600 / 60, x % 60) }
    static func pace(_ s: Double) -> String { let x = Int(s.rounded()); return String(format: "%d:%02d", x / 60, x % 60) }
}
