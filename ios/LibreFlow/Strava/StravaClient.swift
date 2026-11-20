import Foundation
import AuthenticationServices
import Security
import UIKit

/// Strava upload with the user's OWN Strava API application (strava.com/settings/api, free).
/// Nothing is sent to Strava except the one activity file the user confirms in the preview.
/// Client secret and tokens are kept in the iOS Keychain.
@MainActor
final class StravaClient: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = StravaClient()
    static let callbackScheme = "libreflow"
    static let redirectURI = "libreflow://localhost"

    @Published var clientId: String = UserDefaults.standard.string(forKey: "stravaClientId") ?? "" {
        didSet { UserDefaults.standard.set(clientId, forKey: "stravaClientId") }
    }
    @Published var athleteName: String? = UserDefaults.standard.string(forKey: "stravaAthlete")
    var clientSecret: String {
        get { Keychain.get("stravaClientSecret") ?? "" }
        set { Keychain.set("stravaClientSecret", newValue) }
    }
    var isConnected: Bool { Keychain.get("stravaRefreshToken") != nil }

    enum StravaError: LocalizedError {
        case notConfigured, cancelled, http(Int, String), upload(String), timeout
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Enter your Strava Client ID and Client Secret in Settings first."
            case .cancelled: return "Cancelled."
            case .http(let c, let m): return "Strava answered \(c): \(m)"
            case .upload(let m): return m
            case .timeout: return "Strava is still processing the upload. Check Strava in a minute."
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    // MARK: OAuth

    func connect() async throws {
        guard !clientId.isEmpty, !clientSecret.isEmpty else { throw StravaError.notConfigured }
        var c = URLComponents(string: "https://www.strava.com/oauth/mobile/authorize")!
        c.queryItems = [.init(name: "client_id", value: clientId), .init(name: "redirect_uri", value: Self.redirectURI),
                        .init(name: "response_type", value: "code"), .init(name: "approval_prompt", value: "auto"),
                        .init(name: "scope", value: "activity:write")]
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: Self.callbackScheme) { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? StravaError.cancelled) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            s.start()
        }
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value
        else { throw StravaError.upload("Strava did not return an authorisation code (permission refused?).") }
        try await token(["code": code, "grant_type": "authorization_code"])
    }

    func disconnect() {
        for k in ["stravaAccessToken", "stravaRefreshToken", "stravaExpiresAt"] { Keychain.delete(k) }
        athleteName = nil
        UserDefaults.standard.removeObject(forKey: "stravaAthlete")
        objectWillChange.send()
    }

    private func token(_ params: [String: String]) async throws {
        var p = params
        p["client_id"] = clientId; p["client_secret"] = clientSecret
        var req = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = p.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let j = try await send(req)
        guard let access = j["access_token"] as? String, let refresh = j["refresh_token"] as? String,
              let exp = j["expires_at"] as? Double else { throw StravaError.upload("Unexpected token answer from Strava.") }
        Keychain.set("stravaAccessToken", access)
        Keychain.set("stravaRefreshToken", refresh)
        Keychain.set("stravaExpiresAt", String(exp))
        if let a = j["athlete"] as? [String: Any] {
            athleteName = [a["firstname"] as? String, a["lastname"] as? String].compactMap { $0 }.joined(separator: " ")
            UserDefaults.standard.set(athleteName, forKey: "stravaAthlete")
        }
        objectWillChange.send()
    }

    private func accessToken() async throws -> String {
        guard let refresh = Keychain.get("stravaRefreshToken") else { throw StravaError.notConfigured }
        let exp = Double(Keychain.get("stravaExpiresAt") ?? "0") ?? 0
        if exp - 120 < Date().timeIntervalSince1970 { try await token(["refresh_token": refresh, "grant_type": "refresh_token"]) }
        guard let t = Keychain.get("stravaAccessToken") else { throw StravaError.notConfigured }
        return t
    }

    private func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            throw StravaError.http(code, (j["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        return j
    }

    // MARK: upload

    /// Uploads a TCX file and waits until Strava has made an activity of it. Returns the activity id.
    func upload(tcx: String, name: String, externalId: String) async throws -> Int {
        let token = try await accessToken()
        let boundary = "libreflow-\(UUID().uuidString)"
        var body = Data()
        func field(_ n: String, _ v: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        field("data_type", "tcx")
        field("name", name)
        field("external_id", externalId)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(externalId).tcx\"\r\nContent-Type: application/xml\r\n\r\n".data(using: .utf8)!)
        body.append(tcx.data(using: .utf8)!)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "https://www.strava.com/api/v3/uploads")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        var j = try await send(req)
        guard let uploadId = j["id"] as? Int else { throw StravaError.upload("Strava did not accept the file.") }
        for _ in 0..<20 {
            if let e = j["error"] as? String, !e.isEmpty { throw StravaError.upload(e) }
            if let a = j["activity_id"] as? Int { return a }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            var r = URLRequest(url: URL(string: "https://www.strava.com/api/v3/uploads/\(uploadId)")!)
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            j = try await send(r)
        }
        throw StravaError.timeout
    }
}

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "LibreFlow", kSecAttrAccount as String: key]
    }
    static func set(_ key: String, _ value: String) {
        delete(key)
        guard !value.isEmpty else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}
