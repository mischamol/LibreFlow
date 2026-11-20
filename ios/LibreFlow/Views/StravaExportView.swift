import SwiftUI
import MapKit

/// Preview of exactly what would be shared, with an explicit heart-rate choice (off by default).
struct StravaExportView: View {
    let trainingId: String
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
                        } footer: { Text("This route, including where it starts and ends, becomes visible on Strava according to your Strava privacy settings.") }
                    }
                    Section {
                        if strava.isConnected { TextField("Activity name", text: $name) }
                        Toggle("Include heart rate", isOn: $includeHR)
                    } header: { Text("What is sent") } footer: {
                        Text("Sent: GPS route, time, distance, altitude, speed and cadence" + (includeHR ? ", and heart rate (average, maximum and per second)." : ". Heart rate is not sent."))
                    }
                    Section {
                        Button { shareFile(t) } label: { Label("Save file for Strava…", systemImage: "square.and.arrow.up") }
                            .disabled(busy)
                        if strava.isConnected {
                            Button {
                                Task { await upload(t) }
                            } label: {
                                HStack { Text("Upload directly to Strava"); if busy { Spacer(); ProgressView() } }
                            }
                            .disabled(busy || name.isEmpty)
                        }
                    } footer: {
                        Text("Save the file (Files, iCloud Drive or AirDrop to your Mac), then upload it at strava.com › + › Upload activity › File (strava.com/upload/select). On an iPhone, Safari needs \"Request Desktop Website\" for that page. Nothing is sent until you do this yourself.")
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
            .navigationTitle("Export to Strava")
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

    private func shareFile(_ t: DecodedTraining) {
        guard let tcx = TCXWriter.tcx(for: t, includeHeartRate: includeHR) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(trainingId)\(includeHR ? "" : "-no-hr").tcx")
        try? tcx.write(to: url, atomically: true, encoding: .utf8)
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
