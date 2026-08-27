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
        let openAIRoute = ServiceRoute(
            transcriptionModel: .liveTranscribe,
            realtimeURL: URL(string: "wss://relay.example/v1/realtime?provider=openai")!,
            polishURL: URL(string: "https://relay.example/v1/polish")!,
            credential: "test-token"
        )

        #expect(RealtimeClient.sessionTranscriptionModel(
            activeRoute: openAIRoute,
            liveSettingsModel: .geminiLive
        ) == .liveTranscribe)
        #expect(openAIRoute.provider == .openAI)

        // Before a connection owns a route, the current preference remains the source
        // of truth for constructing the first session configuration.
        #expect(RealtimeClient.sessionTranscriptionModel(
            activeRoute: nil,
            liveSettingsModel: .geminiLive
        ) == .geminiLive)
    }
}
