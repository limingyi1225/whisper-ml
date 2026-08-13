import Foundation
import Security

/// Credentials live in the login keychain, not in the binary or in UserDefaults.
public enum KeychainStore {
    private static let service = "com.mingyili.Whisper"
    private static let apiKeyAccount = "openai-api-key"
    private static let relayTokenAccount = "relay-device-token"
    private static let pendingRelayTokenAccount = "relay-pending-enrollment-token"

    public static func loadAPIKey() -> String? {
        load(account: apiKeyAccount)
    }

    public static func loadRelayToken() -> String? {
        load(account: relayTokenAccount)
    }

    /// A generic build proposes its own final device token when claiming an invite.
    /// Keeping that proposal in a separate keychain item makes enrollment idempotent:
    /// if the server commits the invite but the response is lost, the retry presents
    /// the same token and receives success instead of burning a second invite.
    public static func pendingRelayEnrollmentToken() -> String? {
        load(account: pendingRelayTokenAccount)
    }

    public static func prepareRelayEnrollmentToken() throws -> String {
        if let pending = pendingRelayEnrollmentToken(), isGeneratedRelayToken(pending) {
            return pending
        }
        _ = delete(account: pendingRelayTokenAccount)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess,
              let token = relayToken(randomBytes: Data(bytes)),
              save(token, account: pendingRelayTokenAccount) else {
            throw RelayEnrollmentCredentialError.couldNotPrepareToken
        }
        return token
    }

    /// Promotes only after a 200 response. The live item is written first: failure to
    /// remove the now-redundant pending copy is harmless, while removing first and then
    /// failing the live write would lose an invite the server already consumed.
    @discardableResult
    public static func commitPendingRelayEnrollmentToken(expectedToken: String) -> Bool {
        // The caller holds the cross-process enrollment transaction lock. Still bind
        // promotion to the proposal that received 200, so stale responses and future
        // callers cannot promote "whatever happens to be pending".
        let pending = pendingRelayEnrollmentToken()
        switch relayEnrollmentCommitDecision(
            liveToken: loadRelayToken(),
            pendingToken: pending,
            expectedToken: expectedToken
        ) {
        case .alreadyCommitted:
            // Two processes can receive the idempotent 200 for the same proposal.
            // The first has already promoted it, so the missing pending item is success,
            // not a credential-storage failure. Only clean up if it is still ours.
            if pending == expectedToken { _ = delete(account: pendingRelayTokenAccount) }
            return true
        case .promotePending:
            break
        case .reject:
            return false
        }
        guard saveRelayToken(expectedToken) else { return false }
        if pendingRelayEnrollmentToken() == expectedToken {
            _ = delete(account: pendingRelayTokenAccount)
        }
        return true
    }

    public nonisolated static func relayEnrollmentCommitDecision(
        liveToken: String?,
        pendingToken: String?,
        expectedToken: String
    ) -> RelayEnrollmentCommitDecision {
        if liveToken == expectedToken { return .alreadyCommitted }
        if pendingToken == expectedToken { return .promotePending }
        return .reject
    }

    @discardableResult
    public static func resetPendingRelayEnrollmentToken(expectedToken: String) -> Bool {
        // The caller holds the cross-process transaction lock. The value check is for
        // response provenance, not a claim that two separate Keychain calls form CAS.
        guard pendingRelayEnrollmentToken() == expectedToken else { return false }
        return delete(account: pendingRelayTokenAccount)
    }

    public nonisolated static func relayToken(randomBytes: Data) -> String? {
        guard randomBytes.count == 32 else { return nil }
        let encoded = randomBytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "relay_\(encoded)"
    }

    public nonisolated static func isGeneratedRelayToken(_ value: String) -> Bool {
        guard value.hasPrefix("relay_") else { return false }
        let suffix = value.dropFirst(6)
        return suffix.count == 43 && suffix.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    /// A relay device token baked into this copy of the app when it was packaged.
    ///
    /// `script/package_release.sh --for <name>` writes it into `Info.plist` after export
    /// and re-signs, so a build handed to someone else needs no setup at all. Absent in
    /// every ordinary build, including the one on the developer's own machine.
    ///
    /// This is deliberately *only* a relay token, never an OpenAI key. An embedded
    /// string is one `strings` away from anyone holding the binary; what makes that
    /// acceptable here is that the relay confines the token to a fixed model and request
    /// shape, caps its connections and request rate, and lets one hash be revoked
    /// without touching anyone else. None of that is true of an OpenAI key.
    public static var bundledRelayToken: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "WhisperRelayToken")
                as? String,
              value.hasPrefix("relay_") else { return nil }
        return value
    }

    /// Stamped into the one generic distribution build. It carries no credential; it
    /// only tells first launch to offer invite enrollment instead of opening in direct
    /// mode with an empty API-key field.
    public static var inviteEnrollmentEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "WhisperInviteEnrollment") as? Bool == true
    }

    /// When this build's bundled token was issued (epoch seconds), stamped in by
    /// `package_release.sh` beside the token itself.
    ///
    /// Comparing token *values* was not enough to decide whether to install one. Two
    /// facts have to be ordered — which of two tokens is newer — and a digest of a
    /// value cannot answer that. Without it, opening an older personalised copy after a
    /// newer one had installed its token looked exactly like a rotation and downgraded a
    /// working token back to a revoked one. An issuance number makes the order explicit.
    static var bundledTokenIssuance: Int? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "WhisperRelayTokenIssuedAt")
        else { return nil }
        if let number = value as? Int { return number }
        return (value as? String).flatMap(Int.init)
    }

    /// The highest issuance this app has ever installed. A high-water mark, never
    /// cleared — including when the user types a token of their own, because "this
    /// issuance has already been applied here" stays true no matter what replaced it.
    /// Clearing it would let the same build re-install its token on every launch and
    /// overwrite the user's choice forever.
    private static let adoptedIssuanceKey = "adoptedRelayTokenIssuance"

    private static var adoptedIssuance: Int? {
        UserDefaults.standard.object(forKey: adoptedIssuanceKey) as? Int
    }

    private static func recordAdopted(_ issuance: Int?) {
        guard let issuance else { return }
        UserDefaults.standard.set(
            max(issuance, adoptedIssuance ?? Int.min),
            forKey: adoptedIssuanceKey
        )
    }

    /// Installs the token baked into this build, if it should replace what is there.
    ///
    /// The first version only wrote when the keychain was empty, which broke the one
    /// flow the packaging script exists for: revoke someone, hand them a rebuilt copy,
    /// and the revoked token is still sitting in their keychain — so the new one never
    /// lands and they get 401 forever. Deleting the app does not clear a keychain item,
    /// so there was no way out of it from their side.
    ///
    /// Returns true when something was written.
    @discardableResult
    public static func seedBundledRelayTokenIfNeeded() -> Bool {
        guard let bundled = bundledRelayToken else { return false }
        let issuance = bundledTokenIssuance
        guard shouldSeed(
            hasStoredToken: hasRelayToken(),
            bundledIssuance: issuance,
            adoptedIssuance: adoptedIssuance
        ) else { return false }

        guard saveRelayToken(bundled) else { return false }
        recordAdopted(issuance)
        return true
    }

    /// Installs the bundled token in response to the server rejecting what we had.
    @discardableResult
    public static func adoptBundledRelayToken(_ token: String) -> Bool {
        guard saveRelayToken(token) else { return false }
        recordAdopted(bundledTokenIssuance)
        return true
    }

    /// Whether this build's own token is the identity it should be using.
    ///
    /// A personalised build is handed to one person and its token is the hash registered
    /// under their name, so that token — not whatever happens to be in the keychain — is
    /// what makes revoking them work. Installing it once is therefore right even when
    /// something else is already stored, which is the case the value-comparison scheme
    /// got wrong: a recipient who had previously been given someone's shared token kept
    /// using it, so the ledger said "alice = B" while alice's Mac authenticated as A, and
    /// `revoke_token.sh alice` cut off a token nobody was using.
    ///
    /// Ordered by issuance, and only ever forward, which is what keeps that from
    /// becoming a licence to overwrite: the same issuance is never applied twice, so a
    /// token the user types afterwards stays, and an older copy of the app cannot
    /// downgrade a newer token.
    public static func shouldSeed(
        hasStoredToken: Bool,
        bundledIssuance: Int?,
        adoptedIssuance: Int?
    ) -> Bool {
        // A build with a token but no stamp predates issuance tracking; it cannot be
        // ordered against anything, so it may only fill an empty slot. Recovery from a
        // rejected token is the 401 path's job, which needs no ordering.
        guard let bundledIssuance else { return !hasStoredToken }
        guard hasStoredToken else { return true }
        // Something is stored but this app has never applied an issuance: a token typed
        // by hand, or seeded by a build from before this scheme. This build's identity
        // wins, once.
        guard let adoptedIssuance else { return true }
        return bundledIssuance > adoptedIssuance
    }

    /// The recovery decision against this app's own recorded state. The pure function
    /// below carries the reasoning and is what the tests drive.
    static var mayRecoverWithBundledToken: Bool {
        mayRecoverWithBundled(
            bundledIssuance: bundledTokenIssuance,
            adoptedIssuance: adoptedIssuance
        )
    }

    /// Whether a rejected credential may be answered with the bundled token.
    ///
    /// Guards the same downgrade from the other side. Without it, a recipient running
    /// the current build (token B) whose token is later revoked could have an *older*
    /// copy's 401 recovery install A — superseded, already revoked — and then loop.
    public static func mayRecoverWithBundled(
        bundledIssuance: Int?,
        adoptedIssuance: Int?
    ) -> Bool {
        guard let adoptedIssuance else { return true }   // No history to contradict it.
        guard let bundledIssuance else { return false }  // Unorderable against history.
        // `>=`, not `>`: re-installing this build's own token is exactly the repair
        // wanted when the stored value was hand-typed, or was rotated out from under it.
        return bundledIssuance >= adoptedIssuance
    }

    /// Whether a credential is stored, without copying it out.
    ///
    /// The settings pane asks this on every render — which for a pane containing a
    /// `SecureField` means once per keystroke. Answering with `load(…) != nil` decrypted
    /// the item and materialised the plaintext secret each time, purely to compare it
    /// against nil. `kSecReturnData: false` answers the same question from the item's
    /// attributes.
    public static func hasAPIKey() -> Bool { exists(account: apiKeyAccount) }

    public static func hasRelayToken() -> Bool { exists(account: relayTokenAccount) }

    private static func exists(account: String) -> Bool {
        var query: [String: Any] = baseQuery(account: account)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func load(account: String) -> String? {
        var query: [String: Any] = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Returns `true` only when a key was actually written. Whitespace-only input
    /// is rejected rather than treated as a delete — callers report `true` as
    /// "已存入钥匙串", and silently *removing* the key under that message would
    /// leave the user believing the opposite of what happened.
    @discardableResult
    public static func saveAPIKey(_ key: String) -> Bool {
        save(key, account: apiKeyAccount)
    }

    @discardableResult
    public static func saveRelayToken(_ token: String) -> Bool {
        save(token, account: relayTokenAccount)
    }

    private static func save(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let data = Data(trimmed.utf8)
        // Try update first; fall back to insert when there is nothing to update.
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }

        var insert = baseQuery(account: account)
        insert[kSecValueData as String] = data
        // No kSecAttrAccessible here: it is only honored for data-protection
        // keychain items, and this is a file-based login-keychain item — setting
        // it would document a guarantee that is silently not enforced.
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func deleteAPIKey() -> Bool {
        delete(account: apiKeyAccount)
    }

    @discardableResult
    public static func deleteRelayToken() -> Bool {
        delete(account: relayTokenAccount)
    }

    private static func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public enum RelayEnrollmentCommitDecision: Equatable, Sendable {
    case alreadyCommitted
    case promotePending
    case reject
}

public enum RelayEnrollmentCredentialError: LocalizedError {
    case couldNotPrepareToken

    public var errorDescription: String? {
        "无法在钥匙串中准备设备身份"
    }
}
