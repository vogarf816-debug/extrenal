import Foundation
import Security

enum VesperStringVault {
    private static func decode(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.map { $0 ^ 0x5A }, as: UTF8.self)
    }
    static let vesperDashPatchesURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 59, 42, 51, 116, 44, 63, 41, 42, 63, 40, 62, 59, 41, 50, 116, 57, 53, 55, 117, 59, 42, 51, 117, 42, 59, 46, 57, 50, 63, 41])
    static let vesperDashSettingsURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 59, 42, 51, 116, 44, 63, 41, 42, 63, 40, 62, 59, 41, 50, 116, 57, 53, 55, 117, 59, 42, 51, 117, 41, 63, 46, 46, 51, 52, 61, 41])
    static let vesperChannelURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 46, 116, 55, 63, 117, 12, 63, 41, 42, 63, 40, 31, 34, 46, 40, 63, 52, 59, 54])
    static let nullzthURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 46, 116, 55, 63, 117, 20, 47, 54, 54, 0, 46, 50])
    static let nullzthChannelURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 46, 116, 55, 63, 117, 113, 111, 18, 18, 59, 0, 47, 40, 18, 10, 27, 99, 50, 21, 13, 23, 98])
    static let tiktokURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 45, 45, 45, 116, 46, 51, 49, 46, 53, 49, 116, 57, 53, 55, 117, 26, 63, 54, 5, 48, 63, 60, 40, 35, 5, 5, 5, 101, 5, 40, 103, 107, 124, 5, 46, 103, 0, 14, 119, 99, 99, 49, 109, 43, 25, 35, 42, 31, 51, 108, 45])
    static let telegramBaseURL = decode([46, 46, 42, 42, 117, 117, 46, 55, 117])
}
struct VesperDashClientAuthResponse: Decodable {
    let ok: Bool
    let valid: Bool
    let status: String?
    let expires_at: String?
    let contact_owner: String?
    let message: String?
    let access_token: String?
    let access_expires_at: Int?
    let package_passwords: [String]?
}

struct VesperDashClientCredentials: Codable {
    var accessToken: String
    var accessExpiresAt: Int
    var deviceID: String
    var licenseKey: String?
    var deviceName: String
    var systemInfo: String
    var osInfo: String
    var injectedDylibs: Int
    var packagePasswords: [String]
}

enum VesperDashClientSession {
    private static let service = "com.vesperdash.client-session.v1"
    private static let account = "default"

    static func load() -> VesperDashClientCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(VesperDashClientCredentials.self, from: data)
    }

    @discardableResult
    static func store(_ credentials: VesperDashClientCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static var packagePasswords: [String] { load()?.packagePasswords ?? [] }
}

struct VesperDashClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct VesperDashManifest: Decodable {
    let version: Int
    let global_paused: Bool
    let patches: [RemotePatch]
    let all_patches: [RemotePatch]?
}

struct RemotePatch: Codable, Identifiable {
    let id: String
    let name: String
    let category: String?
    let game: String
    let bundle_id: String
    let target_path: String
    let target_paths: [String]?
    let filename: String
    let sha256: String
    let version: String
    let download_url: String
    let image_url: String?
    let status_text: String?
    let sort_order: Int?
    let enabled: Bool
    let paused: Bool

    var normalizedCategory: String {
        let value = (category ?? "aim").lowercased()
        return ["aim", "esp", "hologram", "skin"].contains(value) ? value : "aim"
    }

    var normalizedStatus: String {
        let value = status_text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "NO STATUS" : String(value.prefix(180))
    }

    var displayStatusText: String {
        let value = status_text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(value.prefix(180))
    }

    var normalizedOrder: Int {
        sort_order ?? 1000
    }

    var normalizedTargetPaths: [String] {
        let values = (target_paths ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return values.isEmpty ? [target_path] : values
    }
}

enum VesperDashRemoteSync {
    static let manifestURL = URL(string: VesperStringVault.vesperDashPatchesURL)!

    static func authenticateClient(
        key: String,
        deviceID: String,
        deviceName: String,
        systemInfo: String,
        osInfo: String,
        injectedDylibs: Int
    ) async throws -> VesperDashClientAuthResponse {
        let endpoint = URL(string: "/api/auth/client-session", relativeTo: manifestURL)!.absoluteURL
        let body: [String: Any] = [
            "key": key,
            "device_id": deviceID,
            "device_name": deviceName,
            "system_info": systemInfo,
            "os_info": osInfo,
            "dylibs": String(injectedDylibs)
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VesperDashClientError(message: "VesperDash returned an invalid activation response")
        }
        guard let result = try? JSONDecoder().decode(VesperDashClientAuthResponse.self, from: data) else {
            if http.statusCode == 404 {
                throw VesperDashClientError(message: "VesperDash server update required before activation. Contact the server administrator.")
            }
            throw VesperDashClientError(message: "VesperDash returned an invalid activation response (HTTP \(http.statusCode))")
        }
        if !(200..<300).contains(http.statusCode) && http.statusCode != 401 {
            throw VesperDashClientError(message: result.message ?? "VesperDash activation failed (HTTP \(http.statusCode))")
        }
        return result
    }

    private static func ensureClientCredentials() async throws -> VesperDashClientCredentials {
        guard let current = VesperDashClientSession.load() else {
            throw URLError(.userAuthenticationRequired)
        }
        if current.accessExpiresAt > Int(Date().timeIntervalSince1970) + 90 {
            return current
        }
        guard let key = current.licenseKey else {
            VesperDashClientSession.clear()
            throw URLError(.userAuthenticationRequired)
        }
        let response = try await authenticateClient(
            key: key,
            deviceID: current.deviceID,
            deviceName: current.deviceName,
            systemInfo: current.systemInfo,
            osInfo: current.osInfo,
            injectedDylibs: current.injectedDylibs
        )
        guard response.ok, response.valid,
              let token = response.access_token, !token.isEmpty,
              let expiresAt = response.access_expires_at,
              let passwords = response.package_passwords, !passwords.isEmpty else {
            VesperDashClientSession.clear()
            throw VesperDashClientError(message: response.message ?? "License is not active")
        }
        var refreshed = current
        refreshed.accessToken = token
        refreshed.accessExpiresAt = expiresAt
        refreshed.packagePasswords = passwords
        guard VesperDashClientSession.store(refreshed) else {
            throw VesperDashClientError(message: "Secure session could not be stored on this device")
        }
        return refreshed
    }

    static func authenticatedRequest(for url: URL, timeout: TimeInterval = 30) async throws -> URLRequest {
        let credentials = try await ensureClientCredentials()
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.deviceID, forHTTPHeaderField: "X-Device-ID")
        return request
    }

    static func revokeClientSession(_ credentials: VesperDashClientCredentials) async {
        let endpoint = URL(string: "/api/auth/client-session/logout", relativeTo: manifestURL)!.absoluteURL
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.deviceID, forHTTPHeaderField: "X-Device-ID")
        _ = try? await URLSession.shared.data(for: request)
    }

    static func fetchManifest() async throws -> VesperDashManifest {
        let deadline = Date().addingTimeInterval(120)
        var retryDelay: TimeInterval = 2
        var lastError: Error = URLError(.timedOut)

        while Date() < deadline {
            do {
                let remaining = deadline.timeIntervalSinceNow
                let request = try await authenticatedRequest(
                    for: manifestURL,
                    timeout: min(15, max(1, remaining))
                )
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                guard (200..<300).contains(http.statusCode) else {
                    if http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500 {
                        lastError = URLError(.badServerResponse)
                    } else {
                        throw VesperDashClientError(message: "VesperDash API returned HTTP \(http.statusCode)")
                    }
                    throw ManifestRetrySignal.retry
                }
                return try JSONDecoder().decode(VesperDashManifest.self, from: data)
            } catch is ManifestRetrySignal {
                // The service is starting or temporarily unavailable; retry below.
            } catch let error as URLError {
                guard Self.isTransientManifestError(error.code) else { throw error }
                lastError = error
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            try await Task.sleep(for: .seconds(min(retryDelay, remaining)))
            retryDelay = min(retryDelay * 1.5, 8)
        }
        throw lastError
    }

    private enum ManifestRetrySignal: Error { case retry }

    private static func isTransientManifestError(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .dataNotAllowed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    static func validDownloadURL(for patch: RemotePatch) -> URL? {
        guard let url = URL(string: patch.download_url, relativeTo: manifestURL)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "api.vesperdash.com",
              url.user == nil, url.password == nil,
              patch.bundle_id == "com.dts.freefireth" || patch.bundle_id == "com.dts.freefiremax",
              patch.filename.lowercased().hasSuffix(".3105") else { return nil }
        return url
    }

    static func validImageURL(for patch: RemotePatch) -> URL? {
        guard let value = patch.image_url,
              let url = URL(string: value, relativeTo: manifestURL)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "api.vesperdash.com",
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}


struct VesperAppSettings: Decodable {
    private enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case developerName = "developer_name"
        case developerSubtitle = "developer_subtitle"
        case channelName = "channel_name"
        case channelHandle = "channel_handle"
        case channelURL = "channel_url"
        case ownerName = "owner_name"
        case ownerHandle = "owner_handle"
        case ownerURL = "owner_url"
        case footerText = "footer_text"
    }

    let appName: String
    let developerName: String
    let developerSubtitle: String
    let channelName: String
    let channelHandle: String
    let channelURL: String
    let ownerName: String
    let ownerHandle: String
    let ownerURL: String
    let footerText: String

    static let fallback = VesperAppSettings(
        appName: "Vesper",
        developerName: "Yagami",
        developerSubtitle: "Vesper Developer",
        channelName: "Vesper Telegram",
        channelHandle: "@VesperExternal",
        channelURL: "https://t.me/VesperExternal",
        ownerName: "Yagami",
        ownerHandle: "@YAGAMIxIOS",
        ownerURL: "https://t.me/YAGAMIxIOS",
        footerText: "VESPER • READY"
    )

    init(appName: String, developerName: String, developerSubtitle: String, channelName: String, channelHandle: String, channelURL: String, ownerName: String, ownerHandle: String, ownerURL: String, footerText: String) {
        self.appName = appName; self.developerName = developerName; self.developerSubtitle = developerSubtitle
        self.channelName = channelName; self.channelHandle = channelHandle; self.channelURL = channelURL
        self.ownerName = ownerName; self.ownerHandle = ownerHandle; self.ownerURL = ownerURL; self.footerText = footerText
    }

    init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        let f = VesperAppSettings.fallback
        appName = try d.decodeIfPresent(String.self, forKey: .appName) ?? f.appName
        developerName = try d.decodeIfPresent(String.self, forKey: .developerName) ?? f.developerName
        developerSubtitle = try d.decodeIfPresent(String.self, forKey: .developerSubtitle) ?? f.developerSubtitle
        channelName = try d.decodeIfPresent(String.self, forKey: .channelName) ?? f.channelName
        channelHandle = try d.decodeIfPresent(String.self, forKey: .channelHandle) ?? f.channelHandle
        channelURL = try d.decodeIfPresent(String.self, forKey: .channelURL) ?? f.channelURL
        ownerName = try d.decodeIfPresent(String.self, forKey: .ownerName) ?? f.ownerName
        ownerHandle = try d.decodeIfPresent(String.self, forKey: .ownerHandle) ?? f.ownerHandle
        ownerURL = try d.decodeIfPresent(String.self, forKey: .ownerURL) ?? f.ownerURL
        footerText = try d.decodeIfPresent(String.self, forKey: .footerText) ?? f.footerText
    }
}

extension VesperDashRemoteSync {
    static let settingsURL = URL(string: VesperStringVault.vesperDashSettingsURL)!

    static func fetchAppSettings() async throws -> VesperAppSettings {
        let (data, response) = try await URLSession.shared.data(from: settingsURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(VesperAppSettings.self, from: data)
    }
}
