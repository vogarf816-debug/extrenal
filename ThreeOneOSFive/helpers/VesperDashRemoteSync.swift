enum VesperStringVault {
    private static func decode(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.map { $0 ^ 0x5A }, as: UTF8.self)
    }
    static let m3sbAPIBaseURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 59, 42, 51, 116, 55, 105, 41, 56, 59, 42, 51, 116, 41, 50, 53, 42])
    static let vesperDashPatchesURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 59, 42, 51, 116, 44, 63, 41, 42, 63, 40, 62, 59, 41, 50, 116, 57, 53, 55, 117, 59, 42, 51, 117, 42, 59, 46, 57, 50, 63, 41])
    static let vesperDashResellersURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 59, 42, 51, 116, 44, 63, 41, 42, 63, 40, 62, 59, 41, 50, 116, 57, 53, 55, 117, 59, 42, 51, 117, 40, 63, 41, 63, 54, 54, 63, 40, 41])
    static let vesperChannelURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 46, 116, 55, 63, 117, 12, 63, 41, 42, 63, 40, 31, 34, 46, 40, 63, 52, 59, 54])
    static let nullzthURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 46, 116, 55, 63, 117, 20, 47, 54, 54, 0, 46, 50])
    static let nullzthChannelURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 46, 116, 55, 63, 117, 113, 111, 18, 18, 59, 0, 47, 40, 18, 10, 27, 99, 50, 21, 13, 23, 98])
    static let tiktokURL = decode([50, 46, 46, 42, 41, 96, 117, 117, 45, 45, 45, 116, 46, 51, 49, 46, 53, 49, 116, 57, 53, 55, 117, 26, 63, 54, 5, 48, 63, 60, 40, 35, 5, 5, 5, 101, 5, 40, 103, 107, 124, 5, 46, 103, 0, 14, 119, 99, 99, 49, 109, 43, 25, 35, 42, 31, 51, 108, 45])
    static let telegramBaseURL = decode([46, 46, 42, 42, 117, 117, 46, 55, 117])
}
import Foundation

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
        return value.isEmpty ? "NO STATUS" : value
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

    static func fetchManifest() async throws -> VesperDashManifest {
        var request = URLRequest(url: manifestURL)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        return try decoder.decode(VesperDashManifest.self, from: data)
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

struct OfficialReseller: Codable, Identifiable {
    let id: String
    let name: String
    let handle: String
    let url: String
    let note: String
}

extension VesperDashRemoteSync {
    static let resellersURL = URL(string: VesperStringVault.vesperDashResellersURL)!
    static func fetchOfficialResellers() async throws -> [OfficialReseller] {
        var request = URLRequest(url: resellersURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([OfficialReseller].self, from: data)
    }
}
