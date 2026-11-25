import SwiftUI
import UniformTypeIdentifiers

/// Settings › Watch › Routes: every route kept on this iPhone (GPX imports and routes made from own runs), each with a
/// check mark. The next Sync puts the checked ones on the watch and removes unchecked LibreFlow routes from it.
/// Polar Flow's routes are only listed. No route editing besides the name.
struct RoutesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var sync: WatchSync
    @ObservedObject private var lib = RouteLibrary.shared
    @State private var importing = false
    @State private var pickingRun = false
    @State private var error: String?
    @State private var renaming: RouteLibrary.Entry?
    @State private var newName = ""
    @State private var showLog = false

    private static let gpx: [UTType] = [UTType(filenameExtension: "gpx"), .xml].compactMap { $0 }

    var body: some View {
        List {
            if sync.running {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: sync.progress)
                        Text(sync.lines.last ?? "Syncing…").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } else if let r = sync.lastResult {
                Section { HStack { Text(r).font(.footnote); Spacer(); Button("Log") { showLog = true }.font(.footnote) } }
            }
            Section {
                if lib.entries.isEmpty {
                    Text("No routes yet. Tap + to import a GPX file or to use one of your runs.").foregroundStyle(.secondary)
                }
                ForEach(lib.entries) { e in row(e) }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            } header: { Text("Your routes") } footer: {
                Text("Checked routes are put on the watch at the next Sync; unchecked ones that LibreFlow put there are removed from it. On the watch, start a training and choose a route under Routes or Favorites.\(lib.lastSync.map { "\nLast Sync: \($0)" } ?? "")")
            }
            if !lib.flowRoutes.isEmpty {
                Section {
                    ForEach(lib.flowRoutes, id: \.self) { Label($0, systemImage: "lock").foregroundStyle(.secondary) }
                } header: { Text("From Polar Flow") } footer: { Text("On the watch at the last Sync. LibreFlow never changes these.") }
            }
        }
        .navigationTitle("Routes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if sync.running {
                    Button("Cancel", role: .destructive) { sync.cancel() }
                } else {
                    Button { sync.start() } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { importing = true } label: { Label("Import GPX file…", systemImage: "doc.badge.plus") }
                    Button { pickingRun = true } label: { Label("From a run…", systemImage: "figure.run") }
                } label: { Image(systemName: "plus") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.gpx, allowsMultipleSelection: true) { r in load(r) }
        .sheet(isPresented: $pickingRun) { RunRoutePicker().environmentObject(model) }
        .sheet(isPresented: $showLog) { SyncLogView().environmentObject(sync).environmentObject(model) }
        .alert("Rename route", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let e = renaming { lib.rename(e.id, newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { Text("A route that is already on the watch gets the new name at the next Sync.") }
        #if DEBUG
        .onAppear {   // simulator test hook (the file picker cannot be driven there): SIMCTL_CHILD_LIBREFLOW_TEST_GPX=<path>
            if lib.entries.isEmpty, let p = ProcessInfo.processInfo.environment["LIBREFLOW_TEST_GPX"] { load(.success([URL(fileURLWithPath: p)])) }
        }
        #endif
    }

    private func row(_ e: RouteLibrary.Entry) -> some View {
        let checked = Binding(get: { e.checked }, set: { lib.setChecked(e.id, $0) })
        return Toggle(isOn: checked) {
            HStack(spacing: 12) {
                RouteShape(points: e.route.points).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.route.name).lineLimit(2)
                    Text("\(String(format: "%.1f km", e.route.length / 1000)) · \(e.source) · \(status(e))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu {
            Button { newName = e.route.name; renaming = e } label: { Label("Rename…", systemImage: "pencil") }
            Button(role: .destructive) { lib.delete(e.id) } label: { Label("Delete from LibreFlow", systemImage: "trash") }
        }
        .swipeActions { Button(role: .destructive) { lib.delete(e.id) } label: { Label("Delete", systemImage: "trash") } }
    }

    private func status(_ e: RouteLibrary.Entry) -> String {
        switch (e.checked, e.onWatch) {
        case (true, true): return "on the watch"
        case (true, false): return "added at next Sync"
        case (false, true): return "removed at next Sync"
        case (false, false): return "not on the watch"
        }
    }

    private func load(_ r: Result<[URL], Error>) {
        error = nil
        guard case .success(let urls) = r else { return }
        var failed: [String] = []
        for url in urls {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            do {
                let rt = try PlannedRoute(gpx: try Data(contentsOf: url), fallbackName: url.deletingPathExtension().lastPathComponent)
                lib.add(rt, source: "GPX file")
            } catch { failed.append(url.lastPathComponent) }
        }
        if !failed.isEmpty { error = "Could not read: \(failed.joined(separator: ", ")) (no track or route points)." }
    }
}

/// Routes › + › From a run: the newest activities that have a GPS route; tapping one adds it as a checked route.
struct RunRoutePicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [AppModel.RunChoice]?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if runs == nil { HStack { ProgressView(); Text("Looking for activities with a GPS route…") } }
                if runs?.isEmpty == true { Text("No recent activities with a GPS route.").foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red) }
                ForEach(runs ?? []) { r in
                    Button { add(r) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Self.pretty(r.date)) \(r.time)").foregroundStyle(.primary)
                            Text("\(r.sport) · \(String(format: "%.1f km", r.km))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("From a run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { runs = await model.routeRuns() }
        }
    }

    private func add(_ r: AppModel.RunChoice) {
        guard let raw = model.runRoute(r.key) else { error = "This activity has no GPS route."; return }
        do {
            let name = "\(r.sport.prefix(1).uppercased() + r.sport.dropFirst()) \(Self.pretty(r.date))"
            RouteLibrary.shared.add(try PlannedRoute(run: raw, name: name), source: "Run")
            dismiss()
        } catch { self.error = "This activity has no usable GPS route." }
    }

    /// "2026-11-12" -> "12 Nov 2026"
    static func pretty(_ ymd: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: ymd) else { return ymd }
        let o = DateFormatter(); o.locale = Locale(identifier: "en_GB"); o.dateFormat = "d MMM yyyy"
        return o.string(from: d)
    }
}

/// The route's metre coordinates scaled into the available rectangle (north up); a small circle marks the start.
struct RouteShape: Shape {
    var points: [PlannedRoute.Point]
    func path(in rect: CGRect) -> Path {
        let xs = points.map { Double($0.x) }, ys = points.map { Double($0.y) }
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0, w = max(1, (xs.max() ?? 0) - minX), h = max(1, (ys.max() ?? 0) - minY)
        let s = min(rect.width / w, rect.height / h)
        let ox = rect.minX + (rect.width - w * s) / 2, oy = rect.minY + (rect.height - h * s) / 2
        let pt = { (p: PlannedRoute.Point) in CGPoint(x: ox + (Double(p.x) - minX) * s, y: oy + (h - (Double(p.y) - minY)) * s) }
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: pt(first))
        for p in points.dropFirst() { path.addLine(to: pt(p)) }
        let c = pt(first), r = max(1.5, min(rect.width, rect.height) / 30)
        path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        return path
    }
}
