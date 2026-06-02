import Foundation

/// A newer release the UI can surface (version string + releases URL).
public struct AvailableUpdate: Sendable, Equatable {
    public let version: String
    public let url: String
    public init(version: String, url: String) {
        self.version = version
        self.url = url
    }
}

/// Result of an update check.
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

    public var description: String {
        switch self {
        case let .badCurrentVersion(v): return "current version not SemVer: \(v)"
        case let .transport(r): return "transport error: \(r)"
        case let .httpStatus(c): return "GitHub returned HTTP \(c)"
        case let .decoding(r): return "could not decode release: \(r)"
        case let .unparseableTag(t): return "release tag not SemVer: \(t)"
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

    private let httpClient: HTTPClient
    private let owner: String
    private let repo: String

    public init(httpClient: HTTPClient, owner: String, repo: String) {
        self.httpClient = httpClient
        self.owner = owner
        self.repo = repo
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
