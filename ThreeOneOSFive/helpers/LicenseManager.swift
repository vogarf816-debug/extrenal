import Combine
import Foundation
import MachO
import Security
import UIKit
import CoreFoundation

@MainActor
final class LicenseManager: ObservableObject {
    @Published private(set) var expirationDate: Date?
    @Published private(set) var hasExpiryInformation = false
    @Published private(set) var expiryDateWasProvided = false
    @Published private(set) var lastCheckAttemptAt: Date?
    @Published private(set) var isActive = false
    @Published private(set) var isBusy = false
    @Published private(set) var isLoadingScreen = true
    @Published private(set) var clientSessionRevision = 0
    @Published private(set) var message: String?
    @Published private(set) var contactOwner: String?

    private let service = "com.m3sb.external-ios.activation"
    private let keyAccount = "license-key"
    private let clientSessionAccount = "vesperdash-client-session"
    private let expirationAccount = "license-expiration"
    private let expiryKnownAccount = "license-expiry-known"
    private let expiryPresentAccount = "license-expiry-present"
    private let lastCheckAccount = "license-last-check-expiry-v2"
    private let deviceService = "com.m3sb.api.instance.v1"
    private let deviceAccount = "default"
    private var lastAttemptAt: Date?
    private var silentCheckWorkItem: DispatchWorkItem?
    private var silentCheckID: UUID?

    init() {
        // Keep the app available from the saved key while any revalidation runs silently.
        isActive = string(for: keyAccount) != nil
        hasExpiryInformation = string(for: expiryKnownAccount) == "true"
        expiryDateWasProvided = string(for: expiryPresentAccount) == "true"
        if let value = string(for: expirationAccount), let timestamp = Double(value) {
            expirationDate = Date(timeIntervalSince1970: timestamp)
        }
        if let value = string(for: lastCheckAccount), let timestamp = Double(value) {
            lastCheckAttemptAt = Date(timeIntervalSince1970: timestamp)
        }
        if string(for: clientSessionAccount) != nil { clientSessionRevision = 1 }
        isLoadingScreen = false
    }

    var hasRememberedKey: Bool { string(for: keyAccount) != nil }

    func clientSessionToken() -> String? { string(for: clientSessionAccount) }

    func beginLaunchSession() {
        guard !isBusy else { return }
        guard string(for: keyAccount) != nil else {
            isActive = false
            isLoadingScreen = false
            message = "Key required — enter your access key"
            return
        }
        isActive = true
        isLoadingScreen = false
        guard silentCheckID == nil else { return }
        let checkID = UUID()
        silentCheckID = checkID
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.silentCheckID == checkID else { return }
            self.silentCheckID = nil
            self.silentCheckWorkItem = nil
            guard !self.isBusy, let key = self.string(for: self.keyAccount) else { return }
            self.recordCheckAttempt()
            self.isBusy = true
            self.verify(key: key, silent: true)
        }
        silentCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    func cancelPendingSilentCheck() {
        silentCheckID = nil
        silentCheckWorkItem?.cancel()
        silentCheckWorkItem = nil
    }

    func activate(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        cancelPendingSilentCheck()
        if let lastAttemptAt, Date().timeIntervalSince(lastAttemptAt) < 1 {
            message = "Please wait a moment before trying again"
            return
        }
        lastAttemptAt = Date()
        isBusy = true
        isLoadingScreen = true
        message = "Checking access key…"
        recordCheckAttempt()
        verify(key: trimmed, silent: false)
    }

    func rememberedKey() -> String? { string(for: keyAccount) }

    func refresh() {
        beginLaunchSession()
    }

    func deactivate() {
        cancelPendingSilentCheck()
        revokeClientSession()
        delete(keyAccount)
        delete(clientSessionAccount)
        delete(expirationAccount)
        delete(expiryKnownAccount)
        delete(expiryPresentAccount)
        delete(lastCheckAccount)
        expirationDate = nil
        hasExpiryInformation = false
        expiryDateWasProvided = false
        lastCheckAttemptAt = nil
        isActive = false
        isLoadingScreen = false
        message = "Activation removed from this device"
    }

    private func recordCheckAttempt() {
        let now = Date()
        lastCheckAttemptAt = now
        save(String(now.timeIntervalSince1970), for: lastCheckAccount)
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

    private func revokeClientSession() {
        guard let token = string(for: clientSessionAccount),
              let url = URL(string: VesperStringVault.vesperDashClientSessionURL + "/logout") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request).resume()
    }

    private func verify(key: String, silent: Bool) {
        let deviceID = deviceIdentifier()
        let body: [String: Any] = [
            "key": key,
            "device_id": deviceID,
            "dylibs": String(injectedDylibCount()),
            "device_name": UIDevice.current.name,
            "system_info": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "os_info": UIDevice.current.systemVersion
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]),
              let url = URL(string: VesperStringVault.vesperDashClientSessionURL) else {
            finishVerification(.failure(.message("VesperDash activation service is not configured")), key: key, silent: silent)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result = Self.parseResponse(data: data, response: response, error: error)
            DispatchQueue.main.async {
                self?.finishVerification(result, key: key, silent: silent)
            }
        }.resume()
    }

    private func finishVerification(_ result: Result<APIState, APIError>, key: String, silent: Bool) {
        isBusy = false
        if !silent { isLoadingScreen = false }
        switch result {
        case .success(let state):
            expirationDate = state.expiresAt
            hasExpiryInformation = true
            save("true", for: expiryKnownAccount)
            expiryDateWasProvided = state.hasExpiryField
            save(state.hasExpiryField ? "true" : "false", for: expiryPresentAccount)
            if let expirationDate = state.expiresAt {
                save(String(expirationDate.timeIntervalSince1970), for: expirationAccount)
            } else {
                delete(expirationAccount)
            }
            contactOwner = state.contactOwner
            let normalizedStatus = state.status?.lowercased()
            let hasNotExpired = state.expiresAt.map { $0 > Date() } ?? true
            guard state.valid, state.sessionToken != nil, normalizedStatus != "expired", normalizedStatus != "banned", hasNotExpired else {
                isActive = false
                delete(keyAccount)
                delete(clientSessionAccount)
                delete(expirationAccount)
                delete(expiryKnownAccount)
                delete(expiryPresentAccount)
                expirationDate = nil
                hasExpiryInformation = false
                expiryDateWasProvided = false
                message = state.message ?? "License is not active"
                return
            }
            save(key, for: keyAccount)
            if let sessionToken = state.sessionToken {
                save(sessionToken, for: clientSessionAccount)
                clientSessionRevision += 1
            }
            isActive = true
            if !silent { message = state.message ?? "Activated successfully" }
        case .failure(.message(let error)):
            if !silent {
                isActive = false
                message = error
            }
        case .failure(.revoked(let error)):
            isActive = false
            delete(keyAccount)
            delete(clientSessionAccount)
            delete(expirationAccount)
            delete(expiryKnownAccount)
            delete(expiryPresentAccount)
            expirationDate = nil
            hasExpiryInformation = false
            expiryDateWasProvided = false
            message = error
        }
    }

    private func injectedDylibCount() -> Int {
        let paths = [
            "/library/mobilesubstrate/dynamiclibraries/",
            "/var/jb/library/tweakinject/",
            "/var/jb/usr/lib/tweakinject/",
            "/var/jb/library/mobilesubstrate/dynamiclibraries/"
        ]
        var count = 0
        for index in 0..<_dyld_image_count() {
            guard let image = _dyld_get_image_name(index) else { continue }
            let path = String(cString: image).lowercased()
            guard path.hasSuffix(".dylib"), paths.contains(where: { path.contains($0) }) else { continue }
            count += 1
        }
        return count
    }

    private static func parseResponse(data: Data?, response: URLResponse?, error: Error?) -> Result<APIState, APIError> {
        if let error { return .failure(.message("Connection failed: \(error.localizedDescription)")) }
        guard let http = response as? HTTPURLResponse, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.message("Activation server returned an invalid response"))
        }
        if !(200..<300).contains(http.statusCode) {
            let status = json["status"] as? String
            let serverMessage = json["message"] as? String
            let message = serverMessage ?? status ?? "HTTP \(http.statusCode)"
            if http.statusCode == 403 && (json["valid"] as? Bool == false) {
                return .failure(.revoked(message))
            }
            return .failure(.message("Activation server rejected the request: \(message)"))
        }
        let state = APIState(json: json)
        guard state.valid, state.sessionToken != nil else {
            return .failure(.message("Activation server returned an incomplete session"))
        }
        return .success(state)
    }

    private func deviceIdentifier() -> String {
        if let existing = string(for: deviceAccount, service: deviceService) { return existing }
        let value = UUID().uuidString
        save(value, for: deviceAccount, service: deviceService)
        return value
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
    case revoked(String)
}

private struct APIState {
    let valid: Bool
    let status: String?
    let expiresAt: Date?
    let hasExpiryField: Bool
    let contactOwner: String?
    let message: String?
    let sessionToken: String?

    init(json: [String: Any]) {
        valid = json["valid"] as? Bool ?? false
        status = json["status"] as? String
        contactOwner = json["telegram_username"] as? String
        message = json["message"] as? String
        sessionToken = (json["client_session"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let rawExpiry = json["expires_at"]
        hasExpiryField = rawExpiry != nil && !(rawExpiry is NSNull) && !((rawExpiry as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false)
        if let timestamp = rawExpiry as? NSNumber {
            let rawValue = timestamp.doubleValue
            expiresAt = Date(timeIntervalSince1970: rawValue > 10_000_000_000 ? rawValue / 1000 : rawValue)
        } else if let value = rawExpiry as? String, !value.isEmpty {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var parsed = formatter.date(from: value)
            if parsed == nil {
                formatter.formatOptions = [.withInternetDateTime]
                parsed = formatter.date(from: value)
            }
            if parsed == nil {
                let dateFormatter = DateFormatter()
                dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                dateFormatter.timeZone = TimeZone.current
                for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
                    dateFormatter.dateFormat = format
                    if let date = dateFormatter.date(from: value) {
                        parsed = date
                        break
                    }
                }
            }
            expiresAt = parsed
        } else {
            expiresAt = nil
        }
    }
}
