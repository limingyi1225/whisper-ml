import DictationKit
import Foundation
import Testing

@Suite struct RelayCredentialRegressionTests {
    @Test func enrollmentRequiresTheDocumentedSuccessEnvelope() {
        #expect(RelayEnrollmentClient.isValidSuccessResponse(Data(#"{"ok":true}"#.utf8)))
        #expect(!RelayEnrollmentClient.isValidSuccessResponse(Data(#"{"ok":false}"#.utf8)))
        #expect(!RelayEnrollmentClient.isValidSuccessResponse(Data(#"{"ok":1}"#.utf8)))
        // Additive server fields must stay compatible. This check runs *after* the
        // server has spent the invite, and a rejection here leaves the pending proposal
        // in place — the retry gets the identical idempotent body and fails the same
        // way forever. One new field must not be able to brick every installed client.
        #expect(RelayEnrollmentClient.isValidSuccessResponse(Data(#"{"ok":true,"extra":1}"#.utf8)))
        #expect(!RelayEnrollmentClient.isValidSuccessResponse(Data(#"{"success":true}"#.utf8)))
        #expect(!RelayEnrollmentClient.isValidSuccessResponse(Data("<html>ok</html>".utf8)))
        #expect(!RelayEnrollmentClient.isValidSuccessResponse(Data()))
    }

    @Test func explicitCredentialsAreNewerThanEveryPersonalisedBuild() {
        let oldBuild = 1_700_000_000
        let newerBuild = 1_800_000_000

        // Enrollment and manual writes persist Int.max as an old-build-compatible
        // provenance sentinel. Even an issuance-aware personalised copy that predates
        // the new metadata account therefore cannot seed or 401-recover over it.
        #expect(!KeychainStore.shouldSeed(
            hasStoredToken: true,
            bundledIssuance: oldBuild,
            adoptedIssuance: Int.max
        ))
        #expect(!KeychainStore.shouldSeed(
            hasStoredToken: true,
            bundledIssuance: newerBuild,
            adoptedIssuance: Int.max
        ))
        #expect(!KeychainStore.mayRecoverWithBundled(
            bundledIssuance: newerBuild,
            adoptedIssuance: Int.max
        ))
    }

    @Test func currentBundledMetadataSupersedesHistoricalExplicitHighWater() {
        let currentBundled = 1_800_000_000
        let newerBundled = 1_900_000_000
        let olderBundled = 1_700_000_000
        let baseline = KeychainStore.bundledOrderingBaseline(
            provenanceIssuance: currentBundled,
            adoptedIssuance: Int.max
        )

        #expect(baseline == currentBundled)
        #expect(KeychainStore.shouldSeed(
            hasStoredToken: true,
            bundledIssuance: newerBundled,
            adoptedIssuance: baseline
        ))
        #expect(KeychainStore.mayRecoverWithBundled(
            bundledIssuance: currentBundled,
            adoptedIssuance: baseline
        ))
        #expect(!KeychainStore.shouldSeed(
            hasStoredToken: true,
            bundledIssuance: olderBundled,
            adoptedIssuance: baseline
        ))
        #expect(!KeychainStore.mayRecoverWithBundled(
            bundledIssuance: olderBundled,
            adoptedIssuance: baseline
        ))
    }

    @Test func startupAndRejectedCredentialRecoveryUseDifferentEvidence() {
        let oldIssuance = 1_700_000_000
        let newIssuance = 1_800_000_000

        // A stored token this app never applied an issuance for loses to the build's
        // own identity, once — that is what keeps the relay ledger and the Mac
        // authenticating as the same person.
        #expect(KeychainStore.shouldSeed(
            hasStoredToken: true,
            bundledIssuance: newIssuance,
            adoptedIssuance: nil
        ))
        // But only forward: an issuance already applied is never applied twice, so a
        // token typed afterwards is not overwritten on the next launch.
        #expect(!KeychainStore.shouldSeed(
            hasStoredToken: true,
            bundledIssuance: newIssuance,
            adoptedIssuance: newIssuance
        ))
        // Once a 401 belongs to that exact still-current token, a pre-provenance
        // personalised identity may recover forward according to issuance ordering.
        #expect(KeychainStore.shouldRecoverWithBundled(
            bundledIssuance: newIssuance,
            adoptedIssuance: oldIssuance,
            provenance: .unknown
        ))
        // New manual/enrollment identities carry explicit provenance and never yield to
        // a bundled token automatically, even after rejection.
        #expect(!KeychainStore.shouldRecoverWithBundled(
            bundledIssuance: newIssuance,
            adoptedIssuance: oldIssuance,
            provenance: .explicit
        ))
        // An older personalised copy cannot use 401 recovery to downgrade a newer one.
        #expect(!KeychainStore.shouldRecoverWithBundled(
            bundledIssuance: oldIssuance,
            adoptedIssuance: newIssuance,
            provenance: .unknown
        ))
    }

    @Test func stale401CannotReplaceACredentialWrittenAfterTheOptimisticCheck() {
        let rejected = "relay_\(String(repeating: "a", count: 43))"
        let replacementFromAnotherProcess = "relay_\(String(repeating: "b", count: 43))"

        #expect(KeychainStore.rejectedCredentialIsStillCurrent(
            currentToken: rejected,
            expectedRejectedToken: rejected
        ))
        #expect(!KeychainStore.rejectedCredentialIsStillCurrent(
            currentToken: replacementFromAnotherProcess,
            expectedRejectedToken: rejected
        ))
        #expect(!KeychainStore.rejectedCredentialIsStillCurrent(
            currentToken: nil,
            expectedRejectedToken: rejected
        ))
    }
}
