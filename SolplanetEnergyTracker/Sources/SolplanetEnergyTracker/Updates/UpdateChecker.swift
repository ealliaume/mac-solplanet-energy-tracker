import Foundation

/// A newer release the UI can surface and the installer can act on. Carries the
/// `.zip` (+ optional `.sha256`) download asset URLs needed by the manual
/// install path, plus the release notes Markdown body for the banner sheet.
public struct AvailableUpdate: Sendable, Equatable {
    public let version: SemanticVersion
    public let releaseURL: URL
    public let downloadURL: URL
    public let sha256URL: URL?
    public let publishedAt: Date?
    /// Raw Markdown body of the GitHub release. `nil` when the release has no
    /// description (or it is empty after trimming).
    public let releaseNotes: String?

    public init(
        version: SemanticVersion,
        releaseURL: URL,
        downloadURL: URL,
        sha256URL: URL?,
        publishedAt: Date?,
        releaseNotes: String? = nil
    ) {
        self.version = version
        self.releaseURL = releaseURL
        self.downloadURL = downloadURL
        self.sha256URL = sha256URL
        self.publishedAt = publishedAt
        self.releaseNotes = releaseNotes
    }
}

/// Latest version published on GitHub, plus an `AvailableUpdate` payload only
/// when it is strictly newer than the running build.
public struct UpdateCheckResult: Sendable, Equatable {
    public let latestVersion: SemanticVersion
    public let update: AvailableUpdate?

    public init(latestVersion: SemanticVersion, update: AvailableUpdate?) {
        self.latestVersion = latestVersion
        self.update = update
    }
}

/// Result of the lightweight notify-only update check.
public enum UpdateStatus: Sendable, Equatable {
    case upToDate(current: SemanticVersion)
    case updateAvailable(version: SemanticVersion, releaseURL: String)
}

public enum UpdateCheckError: Error, Equatable, CustomStringConvertible {
    case badCurrentVersion(String)
    case transport(String)
    case httpStatus(Int)
    case decoding(String)
    case unparseableTag(String)
    case missingDownloadAsset(String)

    public var description: String {
        switch self {
        case let .badCurrentVersion(v): return "current version not SemVer: \(v)"
        case let .transport(r): return "transport error: \(r)"
        case let .httpStatus(c): return "GitHub returned HTTP \(c)"
        case let .decoding(r): return "could not decode release: \(r)"
        case let .unparseableTag(t): return "release tag not SemVer: \(t)"
        case let .missingDownloadAsset(n): return "release is missing asset: \(n)"
        }
    }
}

/// Checks the project's latest GitHub release and reports whether it's newer than
/// the running build. Read-only — it never downloads or installs (distribution is
/// undecided; Homebrew deferred per plan §17). The HTTP client is injected so the
/// comparison logic is testable without hitting the network.
public struct UpdateChecker: Sendable {
    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    /// Rich GitHub release shape used by `checkForUpdate` — adds the assets,
    /// body, and publish date the install path and banner need.
    private struct RichGitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let publishedAt: String?
        let body: String?
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case body
            case assets
        }
    }

    private let httpClient: HTTPClient
    private let owner: String
    private let repo: String
    private let downloadAssetName: String

    /// The release asset filename produced by `release.yml` — the contract
    /// shared with the cask `url` and the manual download path. Keep in sync.
    public static let defaultDownloadAssetName = "Solplanet-Energy-Tracker.zip"

    public init(
        httpClient: HTTPClient,
        owner: String,
        repo: String,
        downloadAssetName: String = UpdateChecker.defaultDownloadAssetName
    ) {
        self.httpClient = httpClient
        self.owner = owner
        self.repo = repo
        self.downloadAssetName = downloadAssetName
    }

    /// Rich check used by the auto-update pipeline: returns the latest version
    /// and, when it is strictly newer, an `AvailableUpdate` carrying the `.zip`
    /// + `.sha256` asset URLs and release notes. Throws `missingDownloadAsset`
    /// when a newer release exists but lacks the expected zip — the manual
    /// install path can't proceed without it.
    public func checkForUpdate(currentVersion: SemanticVersion) async throws -> UpdateCheckResult {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(repo, forHTTPHeaderField: "User-Agent") // GitHub requires a UA

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            throw UpdateCheckError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateCheckError.httpStatus(http.statusCode)
        }

        let release: RichGitHubRelease
        do {
            release = try JSONDecoder().decode(RichGitHubRelease.self, from: data)
        } catch {
            throw UpdateCheckError.decoding(String(describing: error))
        }
        guard let latest = SemanticVersion(release.tagName) else {
            throw UpdateCheckError.unparseableTag(release.tagName)
        }
        guard latest > currentVersion else {
            return UpdateCheckResult(latestVersion: latest, update: nil)
        }

        guard let zipAsset = release.assets.first(where: { $0.name == downloadAssetName }),
              let zipURL = URL(string: zipAsset.browserDownloadURL) else {
            throw UpdateCheckError.missingDownloadAsset(downloadAssetName)
        }
        let shaAssetName = "\(downloadAssetName).sha256"
        let shaURL: URL? = release.assets
            .first(where: { $0.name == shaAssetName })
            .flatMap { URL(string: $0.browserDownloadURL) }
        let releaseURL = URL(string: release.htmlURL) ?? zipURL
        let publishedAt: Date? = release.publishedAt.flatMap { raw in
            let formatter = ISO8601DateFormatter() // per-call: not thread-safe
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }
        let trimmedBody: String? = release.body
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        let update = AvailableUpdate(
            version: latest,
            releaseURL: releaseURL,
            downloadURL: zipURL,
            sha256URL: shaURL,
            publishedAt: publishedAt,
            releaseNotes: trimmedBody
        )
        return UpdateCheckResult(latestVersion: latest, update: update)
    }

    public func check(currentVersion: String) async throws -> UpdateStatus {
        guard let current = SemanticVersion(currentVersion) else {
            throw UpdateCheckError.badCurrentVersion(currentVersion)
        }

        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(repo, forHTTPHeaderField: "User-Agent") // GitHub requires a UA

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            throw UpdateCheckError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateCheckError.httpStatus(http.statusCode)
        }

        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateCheckError.decoding(String(describing: error))
        }
        guard let latest = SemanticVersion(release.tagName) else {
            throw UpdateCheckError.unparseableTag(release.tagName)
        }

        return latest > current
            ? .updateAvailable(version: latest, releaseURL: release.htmlURL)
            : .upToDate(current: current)
    }
}
