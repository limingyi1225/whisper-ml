import Foundation

/// A complete, immutable snapshot of the route used for one connection or request.
///
/// Keeping the credential and both endpoints together prevents a settings change between
/// retries from sending one utterance partly direct and partly through the relay.
///
/// The three static constants below are `nonisolated` because the target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise pin them to the
/// main actor and put them out of reach of the `nonisolated` helpers that read them.
/// They are immutable values of `Sendable` types, so there is nothing to isolate.
public struct ServiceRoute: CustomStringConvertible {
    /// This is deployment configuration, not a user preference. Keeping it out of
    /// Settings prevents accidental endpoint changes and leaves one user-facing choice:
    /// connect to OpenAI directly or use the configured relay.
    public nonisolated static let relayBaseURL = URL(string: "https://limingyi.com/whisper-relay")!

    /// Development-only escape hatch, deliberately not in Settings — pointing the app
    /// at a relay is not something a user should be able to do by accident:
    ///
    ///     defaults write com.mingyili.Whisper relayBaseURLOverride http://localhost:8787
    ///     defaults delete com.mingyili.Whisper relayBaseURLOverride
    ///
    /// An unparseable or unsafe value falls back to the production URL rather than
    /// failing the connection, so a stale override cannot brick the app.
    public nonisolated static let relayBaseURLOverrideKey = "relayBaseURLOverride"

    public nonisolated static var relayEnrollmentURL: URL {
        effectiveRelayBaseURL.appendingPathComponent("v1/enroll")
    }

    /// `nonisolated` like the two helpers below: this only reads `UserDefaults`, which
    /// is thread-safe, so there is no reason to pin URL construction to the main actor.
    ///
    /// Debug-only, and loopback-only even there. `UserDefaults` is writable by anything
    /// running as this user, so an override that accepted arbitrary HTTPS hosts would
    /// be a way to make the app hand its Keychain device token to someone else's server
    /// on the next reconnect — the app would be doing the exfiltration itself. Local
    /// development only ever needs loopback, so nothing is lost by refusing the rest.
    public nonisolated static var effectiveRelayBaseURL: URL {
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
    nonisolated private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    public nonisolated static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return loopbackHosts.contains(host)
    }

    public enum ConfigurationError: LocalizedError {
        case message(String)

        public var errorDescription: String? {
            switch self {
            case .message(let message): return message
            }
        }
    }

    /// The model is part of the connection snapshot, not a live preference lookup.
    /// Its provider chooses the WebSocket endpoint and the same value must be reused
    /// for every `session.update` retry on that socket.
    public let transcriptionModel: TranscriptionModel
    public let provider: TranscriptionProvider
    public let realtimeURL: URL
    public let polishURL: URL
    public let credential: String

    public init(
        transcriptionModel: TranscriptionModel = .liveTranscribe,
        realtimeURL: URL,
        polishURL: URL,
        credential: String
    ) {
        self.transcriptionModel = transcriptionModel
        self.provider = transcriptionModel.provider
        self.realtimeURL = realtimeURL
        self.polishURL = polishURL
        self.credential = credential
    }

    public static func current() throws -> ServiceRoute {
        let settings = DictationEnvironment.settings
        guard let token = KeychainStore.loadRelayToken() else {
            throw ConfigurationError.message("还没有设置设备 Token")
        }
        let model = settings.transcriptionModel
        let provider = model.provider
        let base = effectiveRelayBaseURL
        return ServiceRoute(
            transcriptionModel: model,
            realtimeURL: relayRealtimeURL(baseURL: base, provider: provider),
            polishURL: base.appendingPathComponent("v1/polish"),
            credential: token
        )
    }

    /// Production relay addresses must use TLS. Plain HTTP is accepted only for a
    /// loopback development server, so local testing does not require certificates.
    public nonisolated static func relayBaseURL(from raw: String) -> URL? {
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
    public nonisolated var description: String {
        "ServiceRoute(provider: \(provider.rawValue), model: \(transcriptionModel.rawValue), host: \(realtimeURL.host ?? "?"), credential: <redacted>)"
    }

    public nonisolated static func relayRealtimeURL(
        baseURL: URL,
        provider: TranscriptionProvider = .openAI
    ) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/realtime"),
            resolvingAgainstBaseURL: false
        )!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.queryItems = [
            URLQueryItem(name: "intent", value: "transcription"),
            URLQueryItem(name: "provider", value: provider.rawValue),
        ]
        return components.url!
    }
}
