import SwiftUI

/// Running Plan › Send to watch: the next 7 days as favorites. Shows the sessions, then (after reading the watch)
/// exactly what will be written, replaced and removed; writes only after the user confirms, in the same session.
struct PlanToWatchView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var sync: WatchSync
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fav = WatchFavorites()
    @State private var sessions: [PlanFavorite] = []
    @State private var loadError: String?
    @State private var confirmSend = false

    var body: some View {
        NavigationStack {
            Form {
                if let loadError { Text(loadError).foregroundStyle(.secondary) }
                Section {
                    if sessions.isEmpty && loadError == nil { Text("No sessions in the next 7 days.").foregroundStyle(.secondary) }
                    ForEach(sessions) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.subheadline.bold())
                            Text(s.phases.map(Self.describe).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Next 7 days") } footer: {
                    Text("Pace phases use your pace zones (Settings › Training zones): send those to the watch too, so the zone numbers mean the same there.")
                }
                Section { content } header: { Text("Watch") }
            }
            .navigationTitle("Send to watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { fav.cancel(); dismiss() } } }
            .interactiveDismissDisabled(isBusy)
            .task {
                let r = await model.planFavorites()
                sessions = r.sessions; loadError = r.error
            }
        }
    }

    private var isBusy: Bool { if case .writing = fav.phase { return true }; return fav.phase == .reading }

    @ViewBuilder private var content: some View {
        switch fav.phase {
        case .idle, .failed, .done:
            Button { confirmSend = true } label: { Label("Send \(sessions.count) training(s) to the watch…", systemImage: "applewatch") }
                .disabled(sessions.isEmpty || sync.running)
                .confirmationDialog("Send these \(sessions.count) training(s) to the watch?", isPresented: $confirmSend, titleVisibility: .visible) {
                    Button("Send to watch") { Task { await fav.send(sessions) } }
                } message: { Text("They appear under Favorites on the watch. Earlier LibreFlow favorites are replaced or removed; favorites from Polar Flow are never changed. Keep the watch nearby: the app connects once.") }
            if case .failed(let m) = fav.phase { Text(m).foregroundStyle(.red) }
            if case .done(let m) = fav.phase { Text(m).foregroundStyle(.secondary) }
        case .reading:
            HStack { ProgressView(); Text("Connecting and reading the favorites on the watch…") }
        case .ready(let plan):
            ForEach(plan.keep, id: \.slot) { k in Label("\(k.name) (Polar Flow, kept)", systemImage: "lock").font(.footnote).foregroundStyle(.secondary) }
            ForEach(plan.write, id: \.slot) { w in Label("\(w.fav.name)", systemImage: "square.and.arrow.down").font(.footnote) }
            if !plan.remove.isEmpty { Label("\(plan.remove.count) older LibreFlow favorite(s) removed", systemImage: "trash").font(.footnote) }
            Button("Write \(plan.write.count) training(s) to the watch", role: .destructive) { Task { await fav.confirm() } }
            Button("Cancel") { fav.cancel() }
        case .writing(let m):
            HStack { ProgressView(); Text(m) }
        }
    }

    static func describe(_ p: PlanFavorite.Phase) -> String {
        let goal = p.distance ? (p.metres % 1000 == 0 ? "\(p.metres / 1000) km" : String(format: "%.1f km", Double(p.metres) / 1000)) : (p.seconds % 60 == 0 ? "\(p.seconds / 60) min" : "\(p.seconds) s")
        let zone = "\(p.pace ? "pace" : "HR") zone \(p.lo == p.hi ? "\(p.lo)" : "\(p.lo)–\(p.hi)")"
        let rep = p.repeatCount.map { " (×\($0 + 1))" } ?? ""
        return "\(p.name): \(goal), \(zone)\(rep)"
    }
}
