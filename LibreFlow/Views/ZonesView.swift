import SwiftUI

/// Settings › Training zones: five heart-rate zones and five pace zones, automatic or set by hand.
/// The zones live in the analysis page (stored with the data and in backups); nothing is sent to the watch here.
struct ZonesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var sync: WatchSync
    @StateObject private var watch = WatchZones()
    @State private var z = AppModel.Zones()
    @State private var hr: [String] = Array(repeating: "", count: 6)
    @State private var pace: [String] = Array(repeating: "", count: 5)
    @State private var message: String?
    @FocusState private var editing: Bool

    private static let names = ["recovery", "easy (E)", "marathon (M)", "threshold (T)", "interval (I)"]

    var body: some View {
        Form {
            Section {
                Toggle("Automatic", isOn: Binding(get: { z.hrAuto }, set: { on in Task { await save(hr: on ? .some(nil) : .some(z.hr)) } }))
                ForEach(0..<5, id: \.self) { i in
                    HStack {
                        Text("Zone \(i + 1)")
                        Spacer()
                        if i == 0 { field($hr[0], auto: z.hrAuto, keyboard: .numberPad) } else { Text(hr[i]).foregroundStyle(.secondary) }
                        Text("–").foregroundStyle(.secondary)
                        field($hr[i + 1], auto: z.hrAuto, keyboard: .numberPad)
                        Text("bpm").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Heart rate") } footer: {
                Text(z.hrAuto ? "Automatic: from your max and resting heart rate and the two thresholds (Settings › Heart rate)." : "Set by you. Each zone starts where the one before ends.")
            }
            Section {
                Toggle("Automatic", isOn: Binding(get: { z.paceAuto }, set: { on in Task { await save(pace: on ? .some(nil) : .some(z.pace)) } }))
                ForEach(0..<5, id: \.self) { i in
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Zone \(i + 1)")
                            Text(Self.names[i]).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if i == 0 { field($pace[0], auto: z.paceAuto, keyboard: .numbersAndPunctuation) } else { Text(pace[i]).foregroundStyle(.secondary) }
                        Text("–").foregroundStyle(.secondary)
                        if i < 4 { field($pace[i + 1], auto: z.paceAuto, keyboard: .numbersAndPunctuation) } else { Text("faster").foregroundStyle(.secondary) }
                        Text("/km").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Pace") } footer: {
                Text(z.paceAuto ? (z.vdot.map { "Automatic: from your current fitness (VDOT \(String(format: "%.1f", $0))), following Daniels' training paces." } ?? "Automatic: no run of 3 km or more in the last 120 days, so a default fitness is used.") : "Set by you, as min:sec per km. Zone 5 is everything faster than the end of zone 4.")
            }
            if let message { Section { Text(message).foregroundStyle(message == "Zones saved." ? Color.secondary : Color.red) } }
            watchSection
        }
        .navigationTitle("Training zones")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await saveFields() } }.disabled(z.hrAuto && z.paceAuto)
            }
        }
        .task { if let l = await model.loadZones() { show(l) } }
    }

    // MARK: send to the watch

    @ViewBuilder private var watchSection: some View {
        Section {
            switch watch.phase {
            case .reading: HStack { ProgressView(); Text("Reading the running profile from the watch…") }
            case .writing: HStack { ProgressView(); Text("Writing the zones to the watch…") }
            case .preview(let cur, let new, let restore):
                compare("Heart rate", cur.hr.map { "\($0.lowerBound)–\($0.upperBound)" }, new.hr.map { "\($0.lowerBound)–\($0.upperBound)" })
                compare("Pace /km", cur.speed.map(Self.paceRange), new.speed.map(Self.paceRange))
                Button(restore ? "Restore these zones on the watch" : "Write these zones to the watch", role: .destructive) { Task { await watch.confirm() } }
                Button("Cancel") { watch.cancel() }
            default:
                Button { Task { await watch.prepare(hr: z.hr, pace: z.pace) } } label: { Label("Send zones to watch…", systemImage: "applewatch.radiowaves.left.and.right") }
                    .disabled(sync.running || z.hr.count != 6 || z.pace.count != 5 || (z.paceAuto && z.vdot == nil))
                if z.paceAuto && z.vdot == nil {
                    Text("Automatic pace zones need a run of 3 km or more in the last 120 days; until then set them yourself above.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if watch.hasBackup {
                    Button { Task { await watch.prepareRestore() } } label: { Label("Restore original zones…", systemImage: "arrow.uturn.backward") }
                        .disabled(sync.running)
                }
                if case .done(let m) = watch.phase { Text(m).foregroundStyle(.secondary) }
                if case .failed(let m) = watch.phase { Text(m).foregroundStyle(.red) }
            }
        } header: { Text("Watch") } footer: {
            Text("Reads the running sport profile from the watch and shows the zones now and after the change. Only after you confirm, the app writes the profile back with nothing but the zone limits changed, and reads it back to check. Zone 1 keeps its lower limit and zone 5 its upper limit from the watch. The first profile read is kept as a backup. A Polar Flow sync may set the zones from Flow again.")
        }
    }

    private func compare(_ title: String, _ old: [String], _ new: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            ForEach(0..<min(old.count, new.count), id: \.self) { i in
                HStack {
                    Text("Zone \(i + 1)").frame(width: 60, alignment: .leading)
                    Text(old[i]).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    Text(new[i]).bold(old[i] != new[i])
                }.font(.footnote.monospacedDigit())
            }
        }
    }

    private static func pace(_ kmh: Float) -> String {
        guard kmh > 0 else { return "–" }
        let s = Int((3600 / kmh).rounded()); return String(format: "%d:%02d", s / 60, s % 60)
    }
    private static func paceRange(_ r: ClosedRange<Float>) -> String {
        r.upperBound >= 300 ? "faster than \(pace(r.lowerBound))" : r.lowerBound <= 3.1 ? "slower than \(pace(r.upperBound))" : "\(pace(r.lowerBound))–\(pace(r.upperBound))"
    }

    private func field(_ text: Binding<String>, auto: Bool, keyboard: UIKeyboardType) -> some View {
        TextField("", text: text)
            .keyboardType(keyboard).multilineTextAlignment(.trailing).frame(width: 58)
            .disabled(auto).foregroundStyle(auto ? .secondary : .primary).focused($editing)
    }

    private func show(_ l: AppModel.Zones) {
        z = l
        hr = l.hr.map(String.init) + Array(repeating: "", count: max(0, 6 - l.hr.count))
        pace = l.pace.map { String(format: "%d:%02d", $0 / 60, $0 % 60) } + Array(repeating: "", count: max(0, 5 - l.pace.count))
    }

    private func save(hr: [Int]?? = nil, pace: [Int]?? = nil) async {
        guard let l = await model.setZones(hr: hr, pace: pace) else { return }
        message = l.error ?? "Zones saved."
        if l.error == nil { show(l) }
    }

    private func saveFields() async {
        editing = false
        let h = hr.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let p = pace.compactMap { t -> Int? in
            let parts = t.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]), s < 60 else { return nil }
            return m * 60 + s
        }
        if !z.hrAuto && h.count != 6 { message = "Fill in every heart-rate limit as a whole number."; return }
        if !z.paceAuto && p.count != 5 { message = "Fill in every pace limit as min:sec, e.g. 4:45."; return }
        await save(hr: z.hrAuto ? nil : .some(h), pace: z.paceAuto ? nil : .some(p))
    }
}
