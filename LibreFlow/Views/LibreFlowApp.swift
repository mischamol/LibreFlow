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
            .sheet(isPresented: $model.planToWatch) { PlanToWatchView().environmentObject(model).environmentObject(model.sync) }
        }
    }
}

/// One of the four page tabs. They share a single web view, which moves into the visible tab.
struct AnalysisView: View {
    let tag: Int
    let title: String
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            WebSlot(webView: model.webView, active: model.tab == tag)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .syncControls(logButton: true)
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
