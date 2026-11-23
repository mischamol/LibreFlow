import SwiftUI
import WebKit

@main
struct LibreFlowApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView(selection: $model.tab) {
                AnalysisView(tag: 0, title: "Latest Activity")
                    .tabItem { Label("Latest Activity", systemImage: "figure.run") }.tag(0)
                AnalysisView(tag: 1, title: "Analysis")
                    .tabItem { Label("Analysis", systemImage: "chart.xyaxis.line") }.tag(1)
                AnalysisView(tag: 4, title: "Running Plan")
                    .tabItem { Label("Running Plan", systemImage: "calendar") }.tag(4)
                AnalysisView(tag: 2, title: "All Activities")
                    .tabItem { Label("All Activities", systemImage: "list.bullet") }.tag(2)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }.tag(3)
            }
            .onChange(of: model.tab) { _, t in model.showPageView(forTab: t) }
            // back in the foreground (possibly days later): let the page recompute what depends on today's date
            .onChange(of: scenePhase) { _, p in if p == .active { model.webView.evaluateJavaScript("window.appResume && appResume(); 0") } }
            .environmentObject(model)
            .environmentObject(model.sync)
            .environmentObject(StravaClient.shared)
            // a sheet attached here sits outside the .environmentObject scope above: pass the objects explicitly
            .sheet(item: $model.stravaTarget) { t in
                StravaExportView(trainingId: t.id, toStrava: t.toStrava).environmentObject(model).environmentObject(StravaClient.shared)
            }
            .sheet(item: $model.shareURL) { s in ShareSheet(items: [s.url]) }
        }
    }
}

/// One of the three analysis tabs. They share a single web view, which moves into the visible tab.
struct AnalysisView: View {
    let tag: Int
    let title: String
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var sync: WatchSync
    @State private var showLog = false
    @State private var showHelp = false

    var body: some View {
        NavigationStack {
            WebSlot(webView: model.webView, active: model.tab == tag)
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .top, spacing: 0) { statusBar }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showLog = true } label: { Image(systemName: "list.bullet.rectangle") }
                            .accessibilityLabel("Sync log")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if sync.running {
                            Button("Cancel", role: .destructive) { sync.cancel() }
                        } else {
                            Button { sync.start(); showHelp = PolarWatch.savedIdentifier == nil } label: {
                                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                    }
                }
                .sheet(isPresented: $showLog) { SyncLogView() }
                .alert("Sync with your watch", isPresented: $showHelp) {
                    Button("OK") {}
                } message: {
                    Text("The app connects to your watch by itself when it is already paired with this iPhone; you do not need to press anything on the watch. Not found? Press Sync on the watch. First time: put the watch in pairing mode (Settings › General settings › Pair and sync › Pair and sync phone) and accept the pairing request. Only new trainings are read; nothing on the watch is changed.")
                }
        }
    }

    @ViewBuilder private var statusBar: some View {
        if sync.running {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: sync.progress)
                Text(sync.lines.last ?? "Syncing…").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
        } else if let r = sync.lastResult {
            HStack {
                Text(r).font(.footnote)
                Spacer()
                Button("Log") { showLog = true }.font(.footnote)
                Button { sync.lastResult = nil } label: { Image(systemName: "xmark") }.font(.footnote)
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
        }
    }
}

struct SyncLogView: View {
    @EnvironmentObject var sync: WatchSync
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if sync.lines.isEmpty { Text("No sync yet.").foregroundStyle(.secondary) }
                ForEach(Array(sync.lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.footnote.monospaced())
                }
            }
            .navigationTitle("Sync log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.shareURL = .init(url: model.store.root.appendingPathComponent("sync-log.txt")) } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(!FileManager.default.fileExists(atPath: model.store.root.appendingPathComponent("sync-log.txt").path))
                }
            }
        }
    }
}

/// Container that takes the shared web view as soon as its tab is the active one.
struct WebSlot: UIViewRepresentable {
    let webView: WKWebView
    let active: Bool
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ v: UIView, context: Context) {
        v.subviews.filter { $0 !== webView }.forEach { $0.removeFromSuperview() }   // e.g. an old web view after "Delete all data"
        guard active, webView.superview !== v else { return }
        webView.removeFromSuperview()
        webView.frame = v.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.addSubview(webView)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}
