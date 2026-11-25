import SwiftUI

/// The Sync button (Cancel while syncing), the progress / result bar and the sync log, the same on every screen:
/// `.syncControls()`. Tab screens also get the log button at the top left (`logButton: true`); pushed screens keep
/// their back button there and reach the log through the result bar.
struct SyncControls: ViewModifier {
    @EnvironmentObject var sync: WatchSync
    @EnvironmentObject var model: AppModel
    var logButton: Bool
    @State private var showLog = false
    @State private var showHelp = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) { statusBar }
            .toolbar {
                if logButton {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showLog = true } label: { Image(systemName: "list.bullet.rectangle") }
                            .accessibilityLabel("Sync log")
                    }
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
            .sheet(isPresented: $showLog) { SyncLogView().environmentObject(sync).environmentObject(model) }
            .alert("Sync with your watch", isPresented: $showHelp) {
                Button("OK") {}
            } message: {
                Text("The app connects to your watch by itself when it is already paired with this iPhone; you do not need to press anything on the watch. Not found? Press Sync on the watch. First time: put the watch in pairing mode (Settings › General settings › Pair and sync › Pair and sync phone) and accept the pairing request. New trainings are read; the watch is only changed for the routes you checked under Settings › Routes.")
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

extension View {
    func syncControls(logButton: Bool = false) -> some View { modifier(SyncControls(logButton: logButton)) }
}

struct SyncLogView: View {
    @EnvironmentObject var sync: WatchSync
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var logURL: URL { model.store.root.appendingPathComponent("sync-log.txt") }

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
                    Button { model.shareURL = .init(url: logURL) } label: { Image(systemName: "square.and.arrow.up") }
                        .disabled(!FileManager.default.fileExists(atPath: logURL.path))
                }
            }
        }
    }
}
