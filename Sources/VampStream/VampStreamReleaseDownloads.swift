import Foundation

enum VampStreamHomeLinks {
    static let releaseManifest = URL(string: "https://thevamp.app/release.json")!
    static let githubReleases = URL(string: "https://api.github.com/repos/Mesutcydev/vamp-suite/releases?per_page=40")!
    static let syncDownloadPage = URL(string: "https://thevamp.app/sync/#download")!
}

/// Resolves the current Vamp Sync DMG so Stream never ships a pinned build URL.
enum VampStreamReleaseDownloads {
    struct Manifest: Decodable {
        var assets: [String: Asset]

        struct Asset: Decodable {
            var url: String
        }
    }

    struct GitHubRelease: Decodable {
        var draft: Bool
        var prerelease: Bool
        var assets: [Asset]

        struct Asset: Decodable {
            var name: String
            var browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
    }

    static func latestSyncDownload(session: URLSession = .shared) async -> URL {
        if let data = try? await data(from: VampStreamHomeLinks.releaseManifest, session: session),
           let url = syncURL(fromReleaseManifest: data) {
            return url
        }

        var request = URLRequest(url: VampStreamHomeLinks.githubReleases)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("vamp-stream", forHTTPHeaderField: "User-Agent")
        if let data = try? await data(from: request, session: session),
           let url = syncURL(fromGitHubReleases: data) {
            return url
        }

        return VampStreamHomeLinks.syncDownloadPage
    }

    static func syncURL(fromReleaseManifest data: Data) -> URL? {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        return trustedSyncDownload(from: manifest.assets["vamp-mini-host-dmg"]?.url)
    }

    static func syncURL(fromGitHubReleases data: Data) -> URL? {
        guard let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else { return nil }
        let candidates = releases
            .filter { !$0.draft && !$0.prerelease }
            .flatMap(\.assets)
            .compactMap { asset -> (Int, Bool, URL)? in
                guard isSyncDiskImage(asset.name),
                      let url = trustedSyncDownload(from: asset.browserDownloadURL.absoluteString)
                else { return nil }
                return (buildNumber(in: asset.name), asset.name.hasPrefix("VampSync-"), url)
            }
        return candidates.max(by: { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return !lhs.1 && rhs.1
        })?.2
    }

    static func trustedSyncDownload(from urlString: String?) -> URL? {
        guard let urlString, let url = URL(string: urlString), isTrustedSyncDownload(url) else {
            return nil
        }
        return url
    }

    static func isTrustedSyncDownload(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        let host = url.host?.lowercased() ?? ""
        guard isSyncDiskImage(url.lastPathComponent) else { return false }
        return host == "github.com" || host == "www.github.com"
            ? url.path.contains("/Mesutcydev/vamp-suite/releases/download/")
            : false
    }

    static func isSyncDiskImage(_ name: String) -> Bool {
        (name.hasPrefix("VampSync-") || name.hasPrefix("VampMiniHost-")) && name.hasSuffix(".dmg")
    }

    static func buildNumber(in name: String) -> Int {
        guard let range = name.range(of: #"-build-(\d+)"#, options: .regularExpression) else { return 0 }
        return Int(name[range].dropFirst("-build-".count)) ?? 0
    }

    private static func data(from url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await data(from: request, session: session)
    }

    private static func data(from request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
