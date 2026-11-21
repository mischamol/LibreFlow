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
                // --- data in the analysis ---
                Section {
                    Button { importing = true } label: { Label("Import file…", systemImage: "square.and.arrow.down") }
                    Button { Task { await model.pageCommand("backup") } } label: { Label("Make backup", systemImage: "externaldrive") }
                        .disabled(s.count == 0 || s.isDemo)
                    Button { Task { await model.pageCommand("csv") } } label: { Label("Export as CSV", systemImage: "tablecells") }
                        .disabled(s.count == 0)
                    if s.isDemo {
                        Button { Task { await model.pageCommand("reload") } } label: { Label("Back to my own data", systemImage: "arrow.uturn.backward") }
                    } else {
                        Button { Task { await model.pageCommand("demo"); model.tab = 0 } } label: { Label("Try with demo data", systemImage: "wand.and.stars") }
                    }
                    if !model.pageStatus.isEmpty { Text(model.pageStatus).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Import") } footer: {
                    Text("Import your Polar export ZIP (from account.polar.com › Download your data), a backup made with Make backup, or training-session JSON files. Imports are added to what is there; duplicates are skipped. \(s.isDemo ? "Showing demo data (not saved)." : "\(s.count) trainings in the analysis.")")
                }

                // --- heart rate & zones ---
                Section {
                    numberRow("Max heart rate", $hrMax)
                    numberRow("Resting heart rate", $hrRest)
                    numberRow("Aerobic threshold", $aet)
                    numberRow("Anaerobic threshold", $ant)
                    if editing {
                        Button("Apply") { apply() }
                    }
                } header: { Text("Heart rate") } footer: {
                    Text("From your Polar profile when the import contains it. Easy = below the aerobic threshold, hard = above the anaerobic threshold. Used for zones, load and advice.")
                }

                ShoesSection()

                // --- privacy: what exports and uploads contain ---
                Section {
                    Toggle("Include heart rate", isOn: $exportHeartRate)
                    Toggle("Include GPS route", isOn: $exportGPS)
                    Toggle("Show map", isOn: $showMap)
                        .onChange(of: showMap) { _, _ in model.pushMapSetting() }
                } header: { Text("Privacy") } footer: {
                    Text("Show map: routes are shown on OpenStreetMap; the map tiles for the area you view are loaded from openstreetmap.org. Off: the route is drawn without a map and nothing is loaded from the internet. The two switches above apply to Export and To Strava. Heart rate is left out by default. Without the GPS route an export is saved as a TCX file (no map), and the route – including where you start and finish – is not shared.")
                }

                // --- Strava ---
                Section {
                    Toggle("Upload to Strava", isOn: $model.stravaEnabled)
                } header: { Text("Strava") } footer: {
                    Text("Off by default: runs then have an Export button that saves a GPX file (what it contains is set under Privacy) that you can upload yourself, for example to Strava with a free account. When on, that button becomes To Strava and uploads the run directly via the Strava API, which requires a paid Strava subscription and the connection below.")
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
                    Text("Requires a paid Strava subscription (needed for the Strava API at strava.com/settings/api): create an API application with Authorization Callback Domain \"localhost\" and enter its Client ID and Client Secret here. Without it, use the file export.")
                }
                }

                // --- watch ---
                Section {
                    Button(forgotWatch ? "Watch forgotten" : "Forget paired watch") {
                        PolarWatch.savedIdentifier = nil
                        forgotWatch = true
                    }
                    .disabled(forgotWatch || PolarWatch.savedIdentifier == nil)
                } header: { Text("Watch") } footer: {
                    Text("Sync reads only from the watch. To remove the pairing completely, also remove the iPhone on the watch and in iOS Settings › Bluetooth.")
                }

                // --- delete ---
                Section {
                    Button("Delete analysis data", role: .destructive) { confirmClear = true }
                    Button("Delete all data in this app", role: .destructive) { confirmDelete = true }
                } header: { Text("Data") } footer: {
                    Text("All data stays on this iPhone (in the app's folder, also visible in the Files app). No account, no cloud, no tracking.")
                }
            }
            .navigationTitle("Settings")
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
            } message: { Text("Raw watch files stay; they are added again on the next sync or app start.") }
            .confirmationDialog("Delete all trainings and analysis data from this app?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { model.deleteAllData() }
            } message: { Text("This cannot be undone. Your watch and your Polar Flow account are not affected.") }
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
