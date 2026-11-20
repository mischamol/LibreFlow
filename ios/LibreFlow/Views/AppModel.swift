import Foundation
import WebKit
import SwiftUI

/// Shared app state: the analysis web view (kept alive across tabs), the watch sync, and sheets.
@MainActor
final class AppModel: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published var stravaTarget: StravaTarget?
    @Published var shareURL: ShareItem?
    @Published var tab = 0
    /// Settings › Strava: show the To Strava button on runs (off by default)
    @Published var stravaEnabled = UserDefaults.standard.bool(forKey: "stravaEnabled") {
        didSet { UserDefaults.standard.set(stravaEnabled, forKey: "stravaEnabled"); pushStravaSetting() }
    }
    @Published var pageStatus = ""
    @Published var settings = PageSettings()
    @Published var shoes: [Shoe] = []
    @Published var shoeSports: [String] = []
    let sync = WatchSync()
    let store = TrainingStore.shared
    private(set) lazy var webView: WKWebView = makeWebView()
    private var pageReady = false

    struct StravaTarget: Identifiable { let id: String; var toStrava = false }
    struct ShareItem: Identifiable { let id = UUID(); let url: URL }

    /// A pair of shoes as kept by the analysis page (window.appShoes / appSaveShoe / appDeleteShoe).
    struct Shoe: Identifiable, Equatable {
        var id = "", brand = "", model = "", name = "", from = "", display = ""
        var sports: [String] = ["RUNNING", "TRAIL_RUNNING", "TREADMILL_RUNNING"]
        var alertKm = 400.0, startKm = 0.0, km = 0.0
        var retired = false, runs = 0
        var last: String?
        init() {}
        init(_ d: [String: Any]) {
            id = d["id"] as? String ?? ""; brand = d["brand"] as? String ?? ""; model = d["model"] as? String ?? ""
            name = d["name"] as? String ?? ""; from = d["from"] as? String ?? ""; display = d["display"] as? String ?? ""
            sports = d["sports"] as? [String] ?? []; retired = d["retired"] as? Bool ?? false
            alertKm = (d["alertKm"] as? NSNumber)?.doubleValue ?? 0; startKm = (d["startKm"] as? NSNumber)?.doubleValue ?? 0
            km = (d["km"] as? NSNumber)?.doubleValue ?? 0; runs = (d["runs"] as? NSNumber)?.intValue ?? 0; last = d["last"] as? String
        }
        var values: [String: Any] {
            ["brand": brand, "model": model, "name": name, "from": from, "sports": sports, "alertKm": alertKm, "startKm": startKm, "retired": retired]
        }
    }

    /// Settings that live in the analysis page (read/written through window.appSettings / appSetSettings).
    struct PageSettings {
        struct Sport: Identifiable, Hashable { let id: String; let name: String; let count: Int; var on: Bool }
        var count = 0, isDemo = false, hrMaxFromProfile = false
        var hrMax = 0, hrRest = 0, aet = 0, ant = 0
        var sports: [Sport] = []
        init() {}
        init(_ d: [String: Any]) {
            count = d["count"] as? Int ?? 0; isDemo = d["isDemo"] as? Bool ?? false
            hrMaxFromProfile = d["hrMaxFromProfile"] as? Bool ?? false
            hrMax = (d["hrMax"] as? NSNumber)?.intValue ?? 0; hrRest = (d["hrRest"] as? NSNumber)?.intValue ?? 0
            aet = (d["aet"] as? NSNumber)?.intValue ?? 0; ant = (d["ant"] as? NSNumber)?.intValue ?? 0
            sports = (d["sports"] as? [[String: Any]] ?? []).map {
                Sport(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", count: ($0["count"] as? NSNumber)?.intValue ?? 0, on: $0["on"] as? Bool ?? false)
            }
        }
    }

    override init() {
        super.init()
        store.upgradeSessionsIfNeeded()
        sync.onNewTrainings = { [weak self] _ in self?.importPending() }
    }

    private func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(WeakHandler(self), name: "libreflow")
        // hand the stored analysis data to the page before its script runs
        let stored = store.loadAnalysisStore() ?? ""
        let literal = (try? JSONSerialization.data(withJSONObject: [stored])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        ucc.addUserScript(WKUserScript(source: "window.__LIBREFLOW_STORE = \(literal)[0];", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = ucc
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.isInspectable = true
        // privacy: the page may not load anything from the internet
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "no-network",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^(https?|wss?)://"},"action":{"type":"block"}}]"#) { list, _ in
            if let list { wv.configuration.userContentController.add(list) }
            self.loadPage(wv)
        }
        return wv
    }

    private func loadPage(_ wv: WKWebView) {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") else { return }
        wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        showPageView(forTab: tab)
        pushStravaSetting()
        importPending()
        Task { await refreshSettings() }
    }

    /// Give the page every watch training it has not seen yet.
    func importPending() {
        guard pageReady else { return }
        let pending = store.pendingSessions()
        guard !pending.isEmpty,
              let arr = try? JSONSerialization.data(withJSONObject: pending.map(\.json)),
              let js = String(data: arr, encoding: .utf8) else { return }
        webView.evaluateJavaScript("appImport(\(js)); 0") { _, error in
            if error == nil { self.store.markImported(pending.map(\.id)) }
        }
    }

    // messages from the page: {cmd: "store"|"share"|"strava", …}
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let cmd = m["cmd"] as? String else { return }
        switch cmd {
        case "store":
            store.saveAnalysisStore(m["text"] as? String ?? "")
        case "share":
            let name = (m["name"] as? String ?? "export.txt").replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? (m["text"] as? String ?? "").write(to: url, atomically: true, encoding: .utf8)
            shareURL = ShareItem(url: url)
        case "view":   // the page switched view itself (e.g. a run opened from All Runs)
            if let t = ["run": 0, "trends": 1, "runs": 2][m["view"] as? String ?? ""], t != tab { tab = t }
        case "status":
            pageStatus = m["text"] as? String ?? ""
        case "strava":
            if let id = m["id"] as? String { stravaTarget = StravaTarget(id: id, toStrava: m["toStrava"] as? Bool ?? false) }
        default: break
        }
    }

    // MARK: calls into the page

    func pushStravaSetting() {
        guard pageReady else { return }
        webView.evaluateJavaScript("window.appSetStrava && appSetStrava(\(stravaEnabled)); 0")
    }

    /// Show the page view that belongs to an app tab (0 Latest Run, 1 Analysis, 2 All Runs).
    func showPageView(forTab t: Int) {
        guard pageReady, let v = [0: "run", 1: "trends", 2: "runs"][t] else { return }
        webView.evaluateJavaScript("showView('\(v)'); 0")
    }

    private func call(_ js: String, _ args: [String: Any] = [:]) async -> Any? {
        guard pageReady else { return nil }
        return try? await webView.callAsyncJavaScript(js, arguments: args, contentWorld: .page)
    }
    func refreshSettings() async {
        if let d = await call("return window.appSettings ? appSettings() : null") as? [String: Any] { settings = PageSettings(d) }
    }
    func applySettings(hrMax: Int? = nil, hrRest: Int? = nil, aet: Int? = nil, ant: Int? = nil, sports: [String]? = nil) async {
        var o: [String: Any] = [:]
        if let hrMax { o["hrMax"] = hrMax }; if let hrRest { o["hrRest"] = hrRest }
        if let aet { o["aet"] = aet }; if let ant { o["ant"] = ant }; if let sports { o["sports"] = sports }
        if let d = await call("return appSetSettings(o)", ["o": o]) as? [String: Any] { settings = PageSettings(d) }
    }
    private func takeShoes(_ any: Any?) {
        guard let d = any as? [String: Any] else { return }
        shoeSports = d["sports"] as? [String] ?? []
        shoes = (d["shoes"] as? [[String: Any]] ?? []).map(Shoe.init)
    }
    func refreshShoes() async { takeShoes(await call("return window.appShoes ? appShoes() : null")) }
    func saveShoe(_ s: Shoe) async { takeShoes(await call("return appSaveShoe(id, v)", ["id": s.id, "v": s.values])) }
    func deleteShoe(_ id: String) async { takeShoes(await call("return appDeleteShoe(id)", ["id": id])) }

    func pageCommand(_ cmd: String) async {
        if let d = await call("return appCommand(c)", ["c": cmd]) as? [String: Any] { settings = PageSettings(d) }
    }
    /// Import files picked in Settings (backup / training-session JSON / Polar export ZIP).
    func importFiles(_ urls: [URL]) async {
        var texts: [String] = []
        for u in urls {
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            if u.pathExtension.lowercased() == "zip" {
                guard let d = try? Data(contentsOf: u) else { pageStatus = "Could not read \(u.lastPathComponent)."; continue }
                if d.count > 300_000_000 { pageStatus = "\(u.lastPathComponent) is very large (\(d.count / 1_000_000) MB). Make a backup on your Mac and import that instead."; continue }
                _ = await call("return appImportZip(b)", ["b": d.base64EncodedString()])
            } else if let t = try? String(contentsOf: u, encoding: .utf8) {
                texts.append(t)
            } else { pageStatus = "Could not read \(u.lastPathComponent)." }
        }
        if !texts.isEmpty { _ = await call("return appImport(t)", ["t": texts]) }
        await refreshSettings()
    }

    func deleteAllData() {
        store.deleteAll()
        webView.evaluateJavaScript("localStorage.clear(); 0")
        pageReady = false
        let fresh = makeWebView()
        webView = fresh
        objectWillChange.send()
    }
}

/// Avoids the retain cycle WKUserContentController -> handler.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}
