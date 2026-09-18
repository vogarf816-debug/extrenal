import Foundation

struct VesperDashManifest: Decodable {
    let version: Int
    let global_paused: Bool
    let patches: [RemotePatch]
}

struct RemotePatch: Decodable, Identifiable {
    let id: String
    let name: String
    let category: String?
    let game: String
    let bundle_id: String
    let target_path: String
    let filename: String
    let sha256: String
    let version: String
    let download_url: String
    let image_url: String?

    var normalizedCategory: String {
        let value = (category ?? "aim").lowercased()
        return ["aim", "esp", "hologram", "skin"].contains(value) ? value : "aim"
    }
}

enum VesperDashRemoteSync {
    static let manifestURL = URL(string: "https://api.vesperdash.com/api/patches")!

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
