import Foundation

/// A complete, immutable snapshot of the route used for one connection or request.
///
/// Keeping the credential and both endpoints together prevents a settings change between
/// retries from sending one utterance partly direct and partly through the relay.
struct ServiceRoute: CustomStringConvertible {
    /// This is deployment configuration, not a user preference. Keeping it out of
    /// Settings prevents accidental endpoint changes and leaves one user-facing choice:
    /// connect to OpenAI directly or use the configured relay.
    static let relayBaseURL = URL(string: "https://limingyi.com/whisper-relay")!

    /// Development-only escape hatch, deliberately not in Settings — pointing the app
    /// at a relay is not something a user should be able to do by accident:
    ///
    ///     defaults write com.mingyili.Whisper relayBaseURLOverride http://localhost:8787
    ///     defaults delete com.mingyili.Whisper relayBaseURLOverride
    ///
    /// An unparseable or unsafe value falls back to the production URL rather than
    /// failing the connection, so a stale override cannot brick the app.
    static let relayBaseURLOverrideKey = "relayBaseURLOverride"

    /// `nonisolated` like the two helpers below: this only reads `UserDefaults`, which
    /// is thread-safe, so there is no reason to pin URL construction to the main actor.
    ///
    /// Debug-only, and loopback-only even there. `UserDefaults` is writable by anything
    /// running as this user, so an override that accepted arbitrary HTTPS hosts would
    /// be a way to make the app hand its Keychain device token to someone else's server
    /// on the next reconnect — the app would be doing the exfiltration itself. Local
    /// development only ever needs loopback, so nothing is lost by refusing the rest.
    nonisolated static var effectiveRelayBaseURL: URL {
        #if DEBUG
        guard let raw = UserDefaults.standard.string(forKey: relayBaseURLOverrideKey),
              let override = relayBaseURL(from: raw),
              isLoopback(override) else {
            return relayBaseURL
        }
        return override
        #else
        return relayBaseURL
        #endif
    }

    /// One list, used by both the parser (which allows plain HTTP only here) and the
    /// gate below. `URLComponents` keeps IPv6 brackets in `host` on current Foundation,
    /// so both spellings have to be present.
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    nonisolated static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return loopbackHosts.contains(host)
    }

    enum ConfigurationError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let message): return message
            }
        }
    }

    let mode: ConnectionMode
    let realtimeURL: URL
    let polishURL: URL
    let credential: String

    static func current() throws -> ServiceRoute {
        let settings = AppSettings.shared
        switch settings.connectionMode {
        case .direct:
            guard let apiKey = KeychainStore.loadAPIKey() else {
                throw ConfigurationError.message("还没有设置 API Key")
            }
            return ServiceRoute(
                mode: .direct,
                realtimeURL: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!,
                polishURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
                credential: apiKey
            )

        case .relay:
            guard let token = KeychainStore.loadRelayToken() else {
                throw ConfigurationError.message("还没有设置设备 Token")
            }
            let base = effectiveRelayBaseURL
            return ServiceRoute(
                mode: .relay,
                realtimeURL: relayRealtimeURL(baseURL: base),
                polishURL: base.appendingPathComponent("v1/polish"),
                credential: token
            )
        }
    }

    /// Production relay addresses must use TLS. Plain HTTP is accepted only for a
    /// loopback development server, so local testing does not require certificates.
    nonisolated static func relayBaseURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        guard scheme == "https" || (scheme == "http" && loopbackHosts.contains(host)) else {
            return nil
        }

        components.scheme = scheme
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url
    }

    /// Only ever interpolate the redacted form.
    ///
    /// This struct carries a plaintext API key or device token, and it now lives for a
    /// whole utterance (`utteranceRoute`) and is captured by the cleanup `Task`, so it
    /// is in scope at far more log sites than when every request re-read the credential.
    /// The synthesized `description` would print the credential verbatim, and one
    /// `log("\(route)")` added later would put it in the unified log for anyone with
    /// Console.app. Overriding it makes that mistake harmless instead of silent.
    nonisolated var description: String {
        "ServiceRoute(mode: \(mode.rawValue), host: \(realtimeURL.host ?? "?"), credential: <redacted>)"
    }

    nonisolated static func relayRealtimeURL(baseURL: URL) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/realtime"),
            resolvingAgainstBaseURL: false
        )!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        return components.url!
    }
}
