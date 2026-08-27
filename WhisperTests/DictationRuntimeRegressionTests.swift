import AppKit
import ApplicationServices
import CoreFoundation
import Foundation
import Testing
@testable import DictationKit
@testable import Whisper

@Suite struct DictationRuntimeRegressionTests {
    @Test func controllerBackstopNeverPreemptsTheClientsDynamicDeadline() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(DictationController.deferredBackstopDelay(
            clientDeadline: now.addingTimeInterval(80),
            now: now
        ) == 81)
        #expect(DictationController.deferredBackstopDelay(
            clientDeadline: now.addingTimeInterval(5),
            now: now
        ) == 30)
        #expect(DictationController.deferredBackstopDelay(
            clientDeadline: nil,
            now: now
        ) == 30)
    }

    @Test func remoteUploadAllowanceSurvivesLocalWebSocketSendCompletion() {
        let twoMinutesOfPCM = AudioCapture.bytesPerSecond * 120
        let beforeRemoteCommit = RealtimeClient.responseTimeoutInterval(
            rawAudioBytes: twoMinutesOfPCM,
            remoteUploadAcknowledged: false
        )
        let afterRemoteCommit = RealtimeClient.responseTimeoutInterval(
            rawAudioBytes: twoMinutesOfPCM,
            remoteUploadAcknowledged: true
        )

        #expect(abs(afterRemoteCommit - 80) < 0.001)
        #expect(abs(beforeRemoteCommit - 156.8) < 0.001)
        #expect(beforeRemoteCommit > afterRemoteCommit)
    }

    @Test func frozenSelectionOnlyAcceptsTheExpectedSyntheticCaretAdvance() {
        let snapshot = CFRange(location: 12, length: 4)

        #expect(TextInjector.selectionMatches(
            snapshot: snapshot,
            current: snapshot,
            insertedUTF16Count: 0
        ))
        #expect(TextInjector.selectionMatches(
            snapshot: snapshot,
            current: CFRange(location: 17, length: 0),
            insertedUTF16Count: 5
        ))
        #expect(!TextInjector.selectionMatches(
            snapshot: snapshot,
            current: CFRange(location: 18, length: 0),
            insertedUTF16Count: 5
        ))
        #expect(!TextInjector.selectionMatches(
            snapshot: snapshot,
            current: CFRange(location: 17, length: 1),
            insertedUTF16Count: 5
        ))
        #expect(!TextInjector.selectionMatches(
            snapshot: snapshot,
            current: snapshot,
            insertedUTF16Count: -1
        ))
    }

    @Test func opaqueEditorsKeepElementProofButNeverInventRangeProof() {
        let snapshot = CFRange(location: 4, length: 0)

        #expect(TextInjector.selectionProof(
            snapshot: nil,
            current: nil,
            insertedUTF16Count: 0
        ) == nil)
        #expect(TextInjector.selectionProof(
            snapshot: snapshot,
            current: nil,
            insertedUTF16Count: 0
        ) == false)
    }

    @Test func malformedFocusedAXValuesFailClosedBeforeConversion() {
        let malformed = "not an accessibility element" as CFString
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        #expect(TextInjector.checkedAXElement(from: malformed) == nil)
        #expect(TextInjector.checkedAXElement(from: application) != nil)
    }

    /// Live typing is optional, while targeting the wrong same-app control leaks speech.
    /// Missing exact-field evidence therefore falls back to final paste.
    @Test func liveDeltasRequirePositiveExactFieldProof() {
        #expect(!DictationController.canContinueLiveInjection(
            anchorUnchanged: true,
            exactElementFocused: nil
        ))
        #expect(DictationController.canContinueLiveInjection(
            anchorUnchanged: true,
            exactElementFocused: true
        ))
        #expect(!DictationController.canContinueLiveInjection(
            anchorUnchanged: true,
            exactElementFocused: false
        ))
        // The anchor is the one input with no third state, and it still governs.
        #expect(!DictationController.canContinueLiveInjection(
            anchorUnchanged: false,
            exactElementFocused: nil
        ))
        #expect(!DictationController.canContinueLiveInjection(
            anchorUnchanged: false,
            exactElementFocused: true
        ))
    }

    /// Focus identity cannot prove which text Backspace will consume. Only a positive
    /// document read can authorize a destructive rewrite.
    @Test func aRewriteDeletesOnlyWithPositiveTextProof() {
        for element in [nil, true, false] as [Bool?] {
            #expect(!DictationController.rewriteMayDelete(
                typedTextStillBeforeCaret: false,
                sameElementStillFocused: element
            ))
            #expect(DictationController.rewriteMayDelete(
                typedTextStillBeforeCaret: true,
                sameElementStillFocused: element
            ))
            #expect(!DictationController.rewriteMayDelete(
                typedTextStillBeforeCaret: nil,
                sameElementStillFocused: element
            ))
        }
    }

    /// A stale first proof must not survive an inconclusive second read immediately
    /// before Backspace.
    @Test func bothDocumentReadsMustPositivelyAuthorizeDeletion() {
        for element in [nil, true, false] as [Bool?] {
            #expect(!DictationController.rewriteMayStillDelete(
                firstTextProof: true, recheckedTextProof: nil, sameElementStillFocused: element
            ))
            #expect(DictationController.rewriteMayStillDelete(
                firstTextProof: true, recheckedTextProof: true, sameElementStillFocused: element
            ))
        }
        #expect(!DictationController.rewriteMayStillDelete(
            firstTextProof: true, recheckedTextProof: false, sameElementStillFocused: true
        ))
        #expect(!DictationController.rewriteMayStillDelete(
            firstTextProof: nil, recheckedTextProof: nil, sameElementStillFocused: nil
        ))
        #expect(!DictationController.rewriteMayStillDelete(
            firstTextProof: nil, recheckedTextProof: nil, sameElementStillFocused: false
        ))

        // The element term is never evaluated: it cannot strengthen text ownership and
        // costs a blocking cross-process message on the main run loop.
        var elementReads = 0
        _ = DictationController.rewriteMayStillDelete(
            firstTextProof: true,
            recheckedTextProof: nil,
            sameElementStillFocused: { elementReads += 1; return false }()
        )
        #expect(elementReads == 0)
    }

    /// `elementIsStillFocused` answers one question with two very different failures
    /// folded together, and the destructive path used to consume it that way. An
    /// Electron or WebView target publishes no focused element at all — that is the
    /// norm — and reading it as "focus moved" is the exact shape of the bug that broke
    /// cleanup three times.
    @Test func anUnpublishedFocusIsNotADifferentFocus() throws {
        let unrelated = AXUIElementCreateApplication(
            try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier) &+ 10_000
        )
        let pid = try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let other = AXUIElementCreateApplication(pid &+ 20_000)

        // The comparison. A *separately created* element for the same target is the
        // case that matters: the live query always hands back a fresh object, never the
        // pointer captured at the start of the utterance, so comparing by pointer
        // identity instead of CFEqual would answer false for the correct field every
        // single time. Passing one object as both arguments cannot tell those apart.
        let sameTargetAgain = AXUIElementCreateApplication(pid &+ 10_000)
        #expect(TextInjector.focusedElementVerdict(focused: sameTargetAgain, expected: unrelated) == true)
        #expect(TextInjector.focusedElementVerdict(focused: other, expected: unrelated) == false)
        #expect(TextInjector.focusedElementVerdict(focused: nil, expected: unrelated) == nil)

        // And the branch that decides what an AX *failure* means, which is the one this
        // rule keeps getting inverted on. No test can make the running system stop
        // publishing a focused element, so the query's own failure handling has to be
        // reachable separately or it goes unchecked — a mutant returning `false` here
        // breaks cleanup in every Electron target and passes everything else.
        #expect(TextInjector.focusedElementResult(
            status: .cannotComplete, value: nil, expected: unrelated) == nil)
        #expect(TextInjector.focusedElementResult(
            status: .noValue, value: nil, expected: unrelated) == nil)
        #expect(TextInjector.focusedElementResult(
            status: .success, value: nil, expected: unrelated) == nil)
        #expect(TextInjector.focusedElementResult(
            status: .success, value: sameTargetAgain, expected: unrelated) == true)
        #expect(TextInjector.focusedElementResult(
            status: .success, value: other, expected: unrelated) == false)

        // An application element is never the focused *text* element, so the live query
        // is either nil or false — never true.
        #expect(TextInjector.focusedElementMatches(unrelated) != true)
    }

    /// A paste with no AX target at all is still a paste. Requiring one sent whole
    /// classes of editors' transcripts to the clipboard on every single sentence.
    @Test func aPasteWithNoAccessibilityTargetStillGoesToTheApp() throws {
        let frontmost = try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        #expect(TextInjector.targetIsUnmoved(nil, targetPID: frontmost))
        // The app identity is the part that must hold.
        #expect(!TextInjector.targetIsUnmoved(nil, targetPID: frontmost &+ 10_000))
    }

    /// `nil` and `false` are different answers and the distinction has to survive the
    /// helper every caller reads it through.
    @Test func aRangeNobodyPublishedIsNotARangeThatMoved() {
        let here = CFRange(location: 4, length: 0)
        #expect(TextInjector.selectionProof(
            snapshot: nil, current: here, insertedUTF16Count: 0
        ) == nil)
        #expect(TextInjector.selectionProof(
            snapshot: here, current: nil, insertedUTF16Count: 0
        ) == false)
        #expect(TextInjector.selectionProof(
            snapshot: here, current: here, insertedUTF16Count: 0
        ) == true)
    }

    @Test func shortChinesePromptCannotBecomeAnEnglishAnswer() {
        let polisher = TranscriptPolisher()

        #expect(!polisher.isPlausible("I am an AI.", from: "请问你是谁"))
        #expect(!polisher.isPlausible("AI", from: "你是谁"))
        #expect(!polisher.isPlausible("Meeting", from: "开会"))
        #expect(polisher.isPlausible("Kevin", from: "凯文"))
        #expect(polisher.isPlausible("Peter", from: "彼得", vocabulary: ["Peter"]))
        #expect(polisher.isPlausible("Kevin 和 Amy 明天过来", from: "凯文和艾米明天过来"))
    }

    @Test func rehearsalIdentityIsDecidedFromTheCapturedUtterance() {
        #expect(DictationController.isRehearsal(hasTarget: false, isRehearsing: true))
        #expect(!DictationController.isRehearsal(hasTarget: true, isRehearsing: true))
        #expect(!DictationController.isRehearsal(hasTarget: false, isRehearsing: false))
    }

    @Test func queuedRehearsalStaysFrozenIfTheGuideClosesBeforeKeyUp() {
        let frozenWhileLongPressWasConfirmed = DictationController.QueuedGestureIdentity(
            anchor: nil,
            target: nil,
            isRehearsal: true
        )
        let isRehearsingWhenKeyIsReleased = false

        #expect(DictationController.rehearsalAtQueuedRelease(
            frozenWhileLongPressWasConfirmed
        ))
        #expect(DictationController.rehearsalAtQueuedRelease(
            frozenWhileLongPressWasConfirmed
        ) != isRehearsingWhenKeyIsReleased)
    }

    @Test func previousSettlingBeforeQueuedKeyUpPromotesFrozenIdentityAndPrefix() {
        let originalField = DictationController.InjectionAnchor(
            processIdentifier: 101,
            lastForeignInputAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let focusAfterPreviousSettles = DictationController.InjectionAnchor(
            processIdentifier: 202,
            lastForeignInputAt: Date(timeIntervalSinceReferenceDate: 20)
        )
        let originalElement = AXUIElementCreateApplication(101)
        let originalTarget = TextInjectionTarget(
            element: originalElement,
            processIdentifier: 101,
            selection: CFRange(location: 7, length: 0),
            writeEpoch: 0
        )
        let frozenFieldIdentity = DictationController.QueuedGestureIdentity(
            anchor: originalField,
            target: originalTarget,
            isRehearsal: false
        )

        let fieldDisposition = DictationController.deferredGestureDisposition(
            isGestureActive: true,
            frozenIdentity: frozenFieldIdentity
        )
        guard case .startRecording(.promoteCapturedPrefix(let promotedFieldIdentity)) = fieldDisposition else {
            Issue.record("a confirmed queued long press must promote its captured prefix")
            return
        }
        #expect(promotedFieldIdentity.anchor == originalField)
        #expect(promotedFieldIdentity.anchor != focusAfterPreviousSettles)
        #expect(promotedFieldIdentity.target?.processIdentifier == 101)
        #expect(promotedFieldIdentity.target.map {
            CFEqual($0.element, originalElement)
        } == true)
        #expect(promotedFieldIdentity.target?.selection?.location == 7)
        #expect(!promotedFieldIdentity.isRehearsal)

        let frozenRehearsalIdentity = DictationController.QueuedGestureIdentity(
            anchor: nil,
            target: nil,
            isRehearsal: true
        )
        let guideIsRehearsingAfterPreviousSettles = false
        let rehearsalDisposition = DictationController.deferredGestureDisposition(
            isGestureActive: true,
            frozenIdentity: frozenRehearsalIdentity
        )
        guard case .startRecording(.promoteCapturedPrefix(let promotedRehearsal)) = rehearsalDisposition else {
            Issue.record("a queued rehearsal must promote its captured prefix")
            return
        }
        #expect(promotedRehearsal.isRehearsal)
        #expect(promotedRehearsal.isRehearsal != guideIsRehearsingAfterPreviousSettles)

        // A press that has not yet crossed the long-press threshold is not promoted
        // merely because the utterance ahead of it happened to settle first.
        guard case .awaitingLongPress = DictationController.deferredGestureDisposition(
            isGestureActive: true,
            frozenIdentity: nil
        ) else {
            Issue.record("an unconfirmed press must keep waiting for the long-press threshold")
            return
        }
    }

    @Test func monitoringLossPreservesQueuedPrefixWhilePreviousFailureIsDisplayed() {
        #expect(DictationController.shouldPreserveInterruptedQueuedGesture(
            phase: .error("上一句失败"),
            startWhenSettled: true,
            gestureOwnsCapture: true,
            hasFrozenIdentity: true
        ))
        #expect(DictationController.shouldPreserveInterruptedQueuedGesture(
            phase: .idle,
            startWhenSettled: true,
            gestureOwnsCapture: true,
            hasFrozenIdentity: true
        ))
        #expect(!DictationController.shouldPreserveInterruptedQueuedGesture(
            phase: .error("上一句失败"),
            startWhenSettled: true,
            gestureOwnsCapture: true,
            hasFrozenIdentity: false
        ))
    }
}
