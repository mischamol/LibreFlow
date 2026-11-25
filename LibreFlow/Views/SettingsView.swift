import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var strava: StravaClient
    @State private var secret = ""
    @State private var stravaError: String?
    @State private var confirmDelete = false
    @State private var confirmClear = false
    @State private var forgotWatch = false
    @State private var importing = false
    @AppStorage("exportHeartRate") private var exportHeartRate = false
    @AppStorage("exportGPS") private var exportGPS = true
    @AppStorage("showMap") private var showMap = true
    @State private var hrMax = ""
    @State private var hrRest = ""
    @State private var aet = ""
    @State private var ant = ""
    @FocusState private var editing: Bool

    private var s: AppModel.PageSettings { model.settings }

    var body: some View {
        NavigationStack {
            Form {
                // Ordered by how often it is used: training things first, import and reset last.
                Section {
                    NavigationLink { RoutesView() } label: { Label("Routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                    NavigationLink { ZonesView() } label: { Label("Training zones", systemImage: "gauge.with.dots.needle.33percent") }
                } header: { Text("Training") } footer: {
                    Text("Routes: GPX files and your own runs; the checked ones go to the watch at the next Sync. Training zones: used by the running plan, and can be sent to the watch.")
                }

                ShoesSection()

                Section {
                    numberRow("Max heart rate", $hrMax)
                    numberRow("Resting heart rate", $hrRest)
                    numberRow("Aerobic threshold", $aet)
                    numberRow("Anaerobic threshold", $ant)
                    if editing { Button("Apply") { apply() } }
                } header: { Text("Heart rate") } footer: {
                    Text("From your Polar profile when the import contains it. Easy = below the aerobic threshold, hard = above the anaerobic threshold. Used for zones, load and advice.")
                }

                Section {
                    Toggle("Show map", isOn: $showMap)
                        .onChange(of: showMap) { _, _ in model.pushMapSetting() }
                    Toggle("Include heart rate in exports", isOn: $exportHeartRate)
                    Toggle("Include GPS route in exports", isOn: $exportGPS)
                } header: { Text("Privacy") } footer: {
                    Text("Show map: routes are drawn on OpenStreetMap, and only the map tiles for the area you view are loaded from openstreetmap.org; off = drawn without a map, nothing is loaded. The two other switches decide what Export and To Strava contain: heart rate is left out by default, and without the GPS route an export is a TCX file without map, so where you start and finish is not shared.")
                }

                Section {
                    Toggle("Upload to Strava", isOn: $model.stravaEnabled)
                } header: { Text("Strava") } footer: {
                    Text("Off: each activity has Export…, which saves a GPX file you can upload yourself, for example to Strava with a free account. On: that button becomes To Strava… and uploads directly via the Strava API, which needs a paid Strava subscription and the connection below.")
                }
                if model.stravaEnabled {
                    Section {
                        if strava.isConnected {
                            LabeledContent("Connected", value: strava.athleteName ?? "yes")
                            Button("Disconnect Strava", role: .destructive) { strava.disconnect() }
                        } else {
                            TextField("Client ID", text: $strava.clientId).keyboardType(.numberPad)
                            SecureField("Client Secret", text: $secret)
                            Button("Connect Strava") {
                                strava.clientSecret = secret
                                Task {
                                    do { try await strava.connect(); stravaError = nil } catch { stravaError = error.localizedDescription }
                                }
                            }
                            .disabled(strava.clientId.isEmpty || secret.isEmpty)
                            if let stravaError { Text(stravaError).foregroundStyle(.red).font(.footnote) }
                        }
                    } header: { Text("Direct upload (paid Strava subscription)") } footer: {
                        Text("At strava.com/settings/api, create an API application with Authorization Callback Domain \"localhost\" and enter its Client ID and Client Secret here.")
                    }
                }

                Section {
                    Button { Task { await model.pageCommand("backup") } } label: { Label("Make backup", systemImage: "externaldrive") }
                        .disabled(s.count == 0 || s.isDemo)
                    Button { importing = true } label: { Label("Import file…", systemImage: "square.and.arrow.down") }
                    Button { Task { await model.pageCommand("csv") } } label: { Label("Export as CSV", systemImage: "tablecells") }
                        .disabled(s.count == 0)
                    if s.isDemo {
                        Button { Task { await model.pageCommand("reload") } } label: { Label("Back to my own data", systemImage: "arrow.uturn.backward") }
                    } else {
                        Button { Task { await model.pageCommand("demo"); model.tab = 0 } } label: { Label("Try with demo data", systemImage: "wand.and.stars") }
                    }
                    if !model.pageStatus.isEmpty { Text(model.pageStatus).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Your data") } footer: {
                    Text("A backup is a ZIP with all your activities (summary, per-second data and routes), shoes, plan and zones. Import accepts the Polar export ZIP (account.polar.com › Download your data), a backup, or training-session JSON files; imports are added, duplicates skipped. \(s.isDemo ? "Showing demo data (not saved)." : "\(s.count) activities in the analysis.")")
                }

                Section {
                    Button(forgotWatch ? "Watch forgotten" : "Forget paired watch") {
                        PolarWatch.savedIdentifier = nil
                        forgotWatch = true
                    }
                    .disabled(forgotWatch || PolarWatch.savedIdentifier == nil)
                    Button("Delete analysis data", role: .destructive) { confirmClear = true }
                    Button("Delete all data in this app", role: .destructive) { confirmDelete = true }
                } header: { Text("Reset") } footer: {
                    Text("To remove the pairing completely, also remove the iPhone on the watch and in iOS Settings › Bluetooth. All data stays on this iPhone (in the app's folder, also visible in the Files app): no account, no cloud, no tracking.")
                }

                Section {
                    LabeledContent("Version", value: Self.appVersion)
                } header: { Text("About") }
            }
            .navigationTitle("Settings")
            .syncControls(logButton: true)
            .scrollDismissesKeyboard(.interactively)
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Apply") { apply() } } }
            .task { await model.refreshSettings(); await model.refreshShoes(); fill() }
            // attached to the whole screen, not to the shoe rows: refreshing the list must not close the editor
            .sheet(item: $model.editingShoe) { s in ShoeEditView(shoe: s).environmentObject(model) }
            .onChange(of: model.settings.hrMax) { _, _ in if !editing { fill() } }
            .onAppear { secret = strava.clientSecret }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .zip], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { Task { await model.importFiles(urls); fill() } }
            }
            .confirmationDialog("Delete the trainings in the analysis?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await model.pageCommand("clear"); fill() } }
            } message: { Text("Downloaded watch files stay; they are added again at the next Sync or app start. Routes are kept.") }
            .confirmationDialog("Delete all trainings and analysis data from this app?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { model.deleteAllData() }
            } message: { Text("Activities, routes, shoes, plan and zones are deleted from this iPhone. This cannot be undone. Your watch and your Polar Flow account are not affected.") }
        }
    }

    private func numberRow(_ title: String, _ value: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField("–", text: value).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70).focused($editing)
        }
    }

    private func fill() {
        hrMax = s.hrMax > 0 ? "\(s.hrMax)" : ""; hrRest = s.hrRest > 0 ? "\(s.hrRest)" : ""
        aet = s.aet > 0 ? "\(s.aet)" : ""; ant = s.ant > 0 ? "\(s.ant)" : ""
    }

    private func apply() {
        editing = false
        Task {
            await model.applySettings(hrMax: Int(hrMax), hrRest: Int(hrRest), aet: Int(aet), ant: Int(ant))
            fill()
        }
    }
}

extension SettingsView {
    /// "1.2 (202611221530)": marketing version and build number from the app bundle
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }
}
