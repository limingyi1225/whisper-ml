import Foundation
import Testing
@testable import DictationKit

@MainActor
@Suite struct RealtimeProviderPolicyTests {
    @Test func coldFlushStartsTheTurnBeforeAudioAndCommit() {
        #expect(RealtimeClient.bufferedFlushOperations(
            audioChunkCount: 2,
            commitPending: true,
            turnStartPending: true
        ) == [.clear, .append(0), .append(1), .commit])
        #expect(RealtimeClient.bufferedFlushOperations(
            audioChunkCount: 1,
            commitPending: false,
            turnStartPending: true
        ) == [.clear, .append(0)])
        #expect(RealtimeClient.bufferedFlushOperations(
            audioChunkCount: 0,
            commitPending: true,
            turnStartPending: true
        ) == [.clear, .commit])
        #expect(RealtimeClient.bufferedFlushOperations(
            audioChunkCount: 0,
            commitPending: false,
            turnStartPending: true
        ) == [.clear])
        #expect(RealtimeClient.bufferedFlushOperations(
            audioChunkCount: 1,
            commitPending: false,
            turnStartPending: false
        ) == [.clear, .append(0)])
        #expect(RealtimeClient.bufferedFlushOperations(
            audioChunkCount: 0,
            commitPending: false,
            turnStartPending: false
        ).isEmpty)
    }

    @Test func geminiCancellationAlwaysReplacesTheSession() {
        #expect(RealtimeClient.cancellationStrategy(
            provider: .gemini,
            hasKnownItemID: false
        ) == .replaceSession)
        #expect(RealtimeClient.cancellationStrategy(
            provider: .gemini,
            hasKnownItemID: true
        ) == .replaceSession)
    }

    /// Soniox tokens carry no turn identity either; Relay's `soniox-turn-N` is as
    /// synthetic as Gemini's, so a known item id must not be mistaken for proof.
    @Test func sonioxIsHandledLikeGeminiNotLikeOpenAI() {
        #expect(!TranscriptionProvider.soniox.identifiesTurnsItself)
        #expect(!TranscriptionProvider.gemini.identifiesTurnsItself)
        #expect(TranscriptionProvider.openAI.identifiesTurnsItself)
        #expect(RealtimeClient.cancellationStrategy(
            provider: .soniox,
            hasKnownItemID: true
        ) == .replaceSession)
        #expect(RealtimeClient.cancellationStrategy(
            provider: .soniox,
            hasKnownItemID: false
        ) == .replaceSession)
        #expect(RealtimeClient.responseTimeoutStrategy(
            provider: .soniox,
            commitPending: false,
            hasKnownItemID: true
        ) == .replaceSession)
        #expect(RealtimeClient.responseTimeoutStrategy(
            provider: .soniox,
            commitPending: true,
            hasKnownItemID: true
        ) == .discardPendingCommit)
    }

    /// Gemini SMART has already cleaned up. Soniox has not, and is left alone on
    /// purpose: it is the route picked for speed, and the text pass would cost more
    /// time than Soniox saves. Only the OpenAI route takes it.
    @Test func onlyOpenAITakesTheSeparateCleanupPass() {
        #expect(!TranscriptionProvider.gemini.requiresSeparatePolish)
        #expect(!TranscriptionProvider.soniox.requiresSeparatePolish)
        #expect(TranscriptionProvider.openAI.requiresSeparatePolish)
    }

    /// Soniox hands back the sentence as spoken, artifacts of its interims included;
    /// Gemini SMART's final is already clean, and one bound for the separate cleanup
    /// pass must reach that pass untouched.
    @Test func onlySonioxDeliversItsFinalUncleaned() {
        #expect(TranscriptionProvider.soniox.finalIsUncleaned)
        #expect(!TranscriptionProvider.gemini.finalIsUncleaned)
        #expect(!TranscriptionProvider.openAI.finalIsUncleaned)
    }

    /// No selectable model reaches the OpenAI provider any more. Its turn-handling
    /// policy below is still tested because the provider is still shipped.
    @Test func noSelectableModelUsesTheOpenAIProvider() {
        #expect(TranscriptionModel.allCases.allSatisfy { $0.provider != .openAI })
        #expect(TranscriptionModel.allCases.map(\.rawValue)
            == ["gemini-3.5-transcribe-live", "stt-rt-v6"])
    }

    @Test func openAICanClearAKnownTurnInPlace() {
        #expect(RealtimeClient.cancellationStrategy(
            provider: .openAI,
            hasKnownItemID: true
        ) == .clearCurrentTurn)
        #expect(RealtimeClient.cancellationStrategy(
            provider: .openAI,
            hasKnownItemID: false
        ) == .replaceSession)
    }

    @Test func geminiResponseTimeoutAlwaysReplacesACommittedSession() {
        #expect(RealtimeClient.responseTimeoutStrategy(
            provider: .gemini,
            commitPending: false,
            hasKnownItemID: false
        ) == .replaceSession)
        #expect(RealtimeClient.responseTimeoutStrategy(
            provider: .gemini,
            commitPending: false,
            hasKnownItemID: true
        ) == .replaceSession)
    }

    @Test func openAIResponseTimeoutCanRetireAnAuthoritativeItem() {
        #expect(RealtimeClient.responseTimeoutStrategy(
            provider: .openAI,
            commitPending: false,
            hasKnownItemID: true
        ) == .retireCurrentTurn)
        #expect(RealtimeClient.responseTimeoutStrategy(
            provider: .openAI,
            commitPending: false,
            hasKnownItemID: false
        ) == .replaceSession)
    }

    @Test func timeoutBeforeCommitOnlyDropsLocalBuffers() {
        #expect(RealtimeClient.responseTimeoutStrategy(
            provider: .gemini,
            commitPending: true,
            hasKnownItemID: false
        ) == .discardPendingCommit)
        #expect(RealtimeClient.responseTimeoutStrategy(
            provider: .openAI,
            commitPending: true,
            hasKnownItemID: false
        ) == .discardPendingCommit)
    }

    @Test func relayCanRequireReplacementBeforeAResultCallbackStartsTheNextTurn() {
        #expect(RealtimeClient.sessionReplacementRequired(in: [
            "session_replacement_required": true,
        ]))
        #expect(!RealtimeClient.sessionReplacementRequired(in: [:]))
        #expect(!RealtimeClient.sessionReplacementRequired(in: [
            "session_replacement_required": "true",
        ]))
    }

    @Test func sessionConfigRetryKeepsTheModelOwnedByItsConnection() {
        let sonioxRoute = ServiceRoute(
            transcriptionModel: .sonioxLive,
            realtimeURL: URL(string: "wss://relay.example/v1/realtime?provider=soniox")!,
            polishURL: URL(string: "https://relay.example/v1/polish")!,
            credential: "test-token"
        )

        #expect(RealtimeClient.sessionTranscriptionModel(
            activeRoute: sonioxRoute,
            liveSettingsModel: .geminiLive
        ) == .sonioxLive)
        #expect(sonioxRoute.provider == .soniox)

        // Before a connection owns a route, the current preference remains the source
        // of truth for constructing the first session configuration.
        #expect(RealtimeClient.sessionTranscriptionModel(
            activeRoute: nil,
            liveSettingsModel: .geminiLive
        ) == .geminiLive)
    }
}
