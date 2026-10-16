import Combine
import Foundation
import MachO
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
            VesperDashClientSession.clear()
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
        if let credentials = VesperDashClientSession.load() {
            Task { await VesperDashRemoteSync.revokeClientSession(credentials) }
        }
        VesperDashClientSession.clear()
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
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
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
        let deviceID = deviceIdentifier()
        let deviceName = UIDevice.current.name
        let systemInfo = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        let osInfo = UIDevice.current.systemVersion
        let dylibs = injectedDylibCount()
        Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await VesperDashRemoteSync.authenticateClient(
                    key: key,
                    deviceID: deviceID,
                    deviceName: deviceName,
                    systemInfo: systemInfo,
                    osInfo: osInfo,
                    injectedDylibs: dylibs
                )
                let status = state.status?.lowercased() ?? ""
                guard state.ok, state.valid, status != "expired", status != "banned",
                      let token = state.access_token, !token.isEmpty,
                      let expiresAt = state.access_expires_at,
                      let passwords = state.package_passwords, !passwords.isEmpty else {
                    VesperDashClientSession.clear()
                    self.isBusy = false
                    self.isLoadingScreen = false
                    self.isActive = false
                    self.delete(self.keyAccount)
                    self.message = state.message ?? "License is not active"
                    return
                }
                let credentials = VesperDashClientCredentials(
                    accessToken: token,
                    accessExpiresAt: expiresAt,
                    deviceID: deviceID,
                    licenseKey: remember ? key : nil,
                    deviceName: deviceName,
                    systemInfo: systemInfo,
                    osInfo: osInfo,
                    injectedDylibs: dylibs,
                    packagePasswords: passwords
                )
                guard VesperDashClientSession.store(credentials) else {
                    self.isBusy = false
                    self.isLoadingScreen = false
                    self.isActive = false
                    self.message = "Secure session could not be stored on this device"
                    return
                }
                if remember { self.save(key, for: self.keyAccount) }
                self.expirationDate = state.expires_at.flatMap { ISO8601DateFormatter().date(from: $0) }
                self.contactOwner = state.contact_owner
                self.isBusy = false
                self.isLoadingScreen = false
                self.isActive = true
                self.message = state.message ?? "Activated successfully"
            } catch {
                VesperDashClientSession.clear()
                self.isBusy = false
                self.isLoadingScreen = false
                self.isActive = false
                self.message = error.localizedDescription
            }
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
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
