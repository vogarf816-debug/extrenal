import Combine
import CryptoKit
import Foundation
import Security
import UIKit

@MainActor
final class LicenseManager: ObservableObject {
    @Published private(set) var expirationDate: Date?
    @Published private(set) var isActive = false
    @Published private(set) var isBusy = false
    @Published private(set) var isLoadingScreen = true
    @Published private(set) var message: String?
    @Published private(set) var contactOwner: String?
    @Published var rememberKey = true

    private let service = "com.m3sb.external-ios.activation"
    private let keyAccount = "license-key"
    private let deviceService = "com.m3sb.api.instance.v1"
    private let deviceAccount = "default"
    private var lastAttemptAt: Date?

    init() {
        isActive = hasRememberedKey
    }

    var hasRememberedKey: Bool { string(for: keyAccount) != nil }

    func beginLaunchSession() {
        guard !isBusy else { return }
        isLoadingScreen = true
        guard let key = string(for: keyAccount) else {
            isActive = false
            message = "Key required — enter your access key"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
                guard let self, !self.isBusy, !self.isActive else { return }
                self.isLoadingScreen = false
            }
            return
        }
        verify(key: key, remember: true)
    }

    func activate(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        if let lastAttemptAt, Date().timeIntervalSince(lastAttemptAt) < 1 {
            message = "Please wait a moment before trying again"
            return
        }
        lastAttemptAt = Date()
        isBusy = true
        isLoadingScreen = true
        message = "Checking access key…"
        verify(key: trimmed, remember: rememberKey)
    }

    func rememberedKey() -> String? { string(for: keyAccount) }

    func refresh() {
        beginLaunchSession()
    }

    func deactivate() {
        delete(keyAccount)
        isActive = false
        isLoadingScreen = false
        message = "Activation removed from this device"
    }

    private func string(for account: String) -> String? {
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
        return String(data: data, encoding: .utf8)
    }

    private func save(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func verify(key: String, remember: Bool) {
        guard let configuration = APIConfiguration.load() else {
            isBusy = false
            isLoadingScreen = false
            isActive = false
            message = "Subscription API is not configured"
            return
        }

        let deviceID = deviceIdentifier()
        let body: [String: String] = [
            "token": configuration.token,
            "key": key,
            "device_id": deviceID,
            "udid": sha256(deviceID),
            "device_hash": sha256(deviceID),
            "device_name": UIDevice.current.name,
            "system_info": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "os_info": UIDevice.current.systemVersion
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]),
              let url = URL(string: configuration.baseURL + "/api/sdk/verify") else {
            isBusy = false
            isLoadingScreen = false
            isActive = false
            message = "Invalid subscription API configuration"
            return
        }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let bodyHash = sha256(bodyData)
        let canonical = ["M3SB-API-SIGNATURE-V3", "POST", "/api/sdk/verify", timestamp, nonce, bodyHash, configuration.token, key, deviceID].joined(separator: "\n")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("APON/3.0 (iOS)", forHTTPHeaderField: "X-APON-Client")
        request.setValue("3", forHTTPHeaderField: "X-M3SB-Signature-Version")
        request.setValue(timestamp, forHTTPHeaderField: "X-M3SB-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-M3SB-Nonce")
        request.setValue(bodyHash, forHTTPHeaderField: "X-M3SB-Body-SHA256")
        request.setValue(Self.hmac(canonical, secret: configuration.secret), forHTTPHeaderField: "X-M3SB-Signature")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result = Self.parseResponse(data: data, response: response, error: error, secret: configuration.secret)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.isLoadingScreen = false
                switch result {
                case .success(let state):
                    self.expirationDate = state.expiresAt
                    self.contactOwner = state.contactOwner
                    guard state.valid, state.status != "expired", state.status != "banned" else {
                        self.isActive = false
                        self.delete(self.keyAccount)
                        self.message = state.message ?? "License is not active"
                        return
                    }
                    if remember { self.save(key, for: self.keyAccount) }
                    self.isActive = true
                    self.message = state.message ?? "Activated successfully"
                case .failure(.message(let error)):
                    self.isActive = false
                    self.message = error
                }
            }
        }.resume()
    }

    private static func parseResponse(data: Data?, response: URLResponse?, error: Error?, secret: String) -> Result<APIState, APIError> {
        if let error { return .failure(.message("Connection failed: \(error.localizedDescription)")) }
        guard let http = response as? HTTPURLResponse, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.message("Subscription server returned an invalid response"))
        }
        if !(200..<300).contains(http.statusCode) {
            let status = json["status"] as? String
            let serverMessage = json["message"] as? String
            return .failure(.message("Subscription server rejected the request: \(serverMessage ?? status ?? "HTTP \(http.statusCode)")"))
        }
        let state = APIState(json: json)
        guard !state.valid || verifyResponse(json: json, secret: secret) else {
            return .failure(.message("Subscription response could not be trusted"))
        }
        return .success(state)
    }

    private static func verifyResponse(json: [String: Any], secret: String) -> Bool {
        guard let signature = json["sig_v2"] as? String, !signature.isEmpty,
              let rawTimestamp = json["ts"] as? NSNumber else { return false }

        // Accept seconds or milliseconds, while still enforcing a short freshness window.
        let rawTime = rawTimestamp.doubleValue
        let timestamp = rawTime > 10_000_000_000 ? rawTime / 1000.0 : rawTime
        guard abs(Date().timeIntervalSince1970 - timestamp) <= 300 else { return false }

        let fields = ["valid", "status", "license", "device_hash", "expires_at", "devices_left", "allow_inject", "ts"]
        let payload = fields.map { field -> String in
            guard let value = json[field], !(value is NSNull) else { return "\(field)=" }
            if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
                return "\(field)=\(((value as? Bool) ?? false) ? "true" : "false")"
            }
            if let value = value as? NSNumber { return "\(field)=\(value.stringValue)" }
            return "\(field)=\(value)"
        }.joined(separator: "&")

        let expected = Self.hmac(payload, secret: secret)
        let actualBytes = Array(signature.utf8)
        let expectedBytes = Array(expected.utf8)
        guard actualBytes.count == expectedBytes.count else { return false }
        var difference: UInt8 = 0
        for index in actualBytes.indices { difference |= actualBytes[index] ^ expectedBytes[index] }
        return difference == 0
    }

    private func deviceIdentifier() -> String {
        if let existing = string(for: deviceAccount, service: deviceService) { return existing }
        let value = UUID().uuidString
        save(value, for: deviceAccount, service: deviceService)
        return value
    }

    private func sha256(_ value: String) -> String { sha256(Data(value.utf8)) }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ value: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        return HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key).map { String(format: "%02x", $0) }.joined()
    }

    private func string(for account: String, service: String) -> String? {
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
        return String(data: data, encoding: .utf8)
    }

    private func save(_ value: String, for account: String, service: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

private enum APIError: Error {
    case message(String)
}

private struct APIConfiguration {
    let baseURL: String
    let token: String
    let secret: String

    static func load() -> APIConfiguration? {
        guard let baseURL = Bundle.main.object(forInfoDictionaryKey: "M3SB_API_BASE_URL") as? String,
              let token = Bundle.main.object(forInfoDictionaryKey: "M3SB_PACKAGE_TOKEN") as? String,
              let secret = Bundle.main.object(forInfoDictionaryKey: "M3SB_HMAC_SECRET") as? String,
              let url = URL(string: baseURL), url.scheme == "https", url.host != nil,
              !token.isEmpty, !secret.isEmpty, !token.hasPrefix("$("), !secret.hasPrefix("$(") else { return nil }
        return APIConfiguration(baseURL: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")), token: token, secret: secret)
    }
}

private struct APIState {
    let valid: Bool
    let status: String?
    let expiresAt: Date?
    let contactOwner: String?
    let message: String?

    init(json: [String: Any]) {
        valid = json["valid"] as? Bool ?? false
        status = json["status"] as? String
        contactOwner = json["telegram_username"] as? String
        message = json["message"] as? String
        if let value = json["expires_at"] as? String { expiresAt = ISO8601DateFormatter().date(from: value) } else { expiresAt = nil }
    }
}
