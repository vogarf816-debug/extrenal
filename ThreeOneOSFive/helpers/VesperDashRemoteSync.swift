import Foundation

struct VesperDashManifest: Decodable {
    let version: Int
    let patches: [RemotePatch]
}

struct RemotePatch: Decodable, Identifiable {
    let id: String
    let name: String
    let game: String
    let bundle_id: String
    let target_path: String
    let filename: String
    let sha256: String
    let version: String
    let download_url: String
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
}
