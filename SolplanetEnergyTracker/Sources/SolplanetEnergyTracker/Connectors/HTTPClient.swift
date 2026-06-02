import Foundation

/// Injectable HTTP seam so the connector can be tested without a live dongle
/// (see `docs/SWIFT-TESTABILITY.md`). `URLSession` already provides `data(for:)`.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClient {}

/// Pure trust decision, extracted from the `URLSessionDelegate` so it can be unit
/// tested without a real TLS handshake. The dongle's self-signed certificate is
/// trusted **only** for hosts the user configured; everything else falls through
/// to the system's normal validation. See `docs/SWIFT-IO-ROBUSTNESS.md`.
public enum SelfSignedTrust {
    public enum Disposition: Equatable {
        /// Accept the server-presented (self-signed) trust — our pinned dongle.
        case useServerTrust
        /// Not our dongle → let the system apply default validation.
        case performDefault
    }

    public static func evaluate(host: String, authenticationMethod: String,
                                trustedHosts: Set<String>) -> Disposition {
        guard authenticationMethod == NSURLAuthenticationMethodServerTrust,
              trustedHosts.contains(host) else {
            return .performDefault
        }
        return .useServerTrust
    }
}

/// `URLSessionDelegate` that applies `SelfSignedTrust` to incoming challenges.
public final class SelfSignedSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    private let trustedHosts: Set<String>

    public init(trustedHosts: Set<String>) {
        self.trustedHosts = trustedHosts
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let decision = SelfSignedTrust.evaluate(
            host: challenge.protectionSpace.host,
            authenticationMethod: challenge.protectionSpace.authenticationMethod,
            trustedHosts: trustedHosts
        )
        switch decision {
        case .useServerTrust:
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        case .performDefault:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

public enum SolplanetSession {
    /// Builds a `URLSession` that trusts the self-signed certs of `trustedHosts`
    /// and nothing else.
    public static func make(trustedHosts: Set<String>) -> URLSession {
        URLSession(
            configuration: .ephemeral,
            delegate: SelfSignedSessionDelegate(trustedHosts: trustedHosts),
            delegateQueue: nil
        )
    }
}
