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

    /// The rule three separate shipped regressions broke: a control that publishes no
    /// focused element has not denied anything. `nil` must read like `true` here and
    /// unlike `false`, or every sentence in an Electron or WebView editor is abandoned
    /// on its first delta and dumped to the clipboard.
    @Test func liveDeltasTreatAnUnobservableFieldAsPermissionNotRefusal() {
        #expect(DictationController.canContinueLiveInjection(
            anchorUnchanged: true,
            exactElementFocused: nil
        ))
        #expect(DictationController.canContinueLiveInjection(
            anchorUnchanged: true,
            exactElementFocused: true
        ))
        // Silence is permission; a positive contradiction is not.
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

    /// Same rule on the destructive side, where getting it wrong is what "整理功能全面
    /// 坏了" looked like: the raw deltas stay on screen and the cleaned sentence lands
    /// on the clipboard instead.
    @Test func aRewriteDeletesWhenTheDocumentIsSilentButNotWhenItDisagrees() {
        // The full truth table, because the interesting half of it is the diagonal.
        for element in [nil, true, false] as [Bool?] {
            // A document that contradicts us is disproof no matter what focus says.
            #expect(!DictationController.rewriteMayDelete(
                typedTextStillBeforeCaret: false,
                sameElementStillFocused: element
            ))
            // A document that confirms us is proof no matter what focus says — the
            // element mismatch below is the common case, not the alarming one: apps
            // rebuild their accessibility tree around text just typed into them and
            // hand out a fresh object for the very field we are still addressing.
            #expect(DictationController.rewriteMayDelete(
                typedTextStillBeforeCaret: true,
                sameElementStillFocused: element
            ))
        }
        // With no text proof, focus is the only evidence left. Silence permits;
        // the system naming some *other* element is the one case that refuses.
        #expect(DictationController.rewriteMayDelete(
            typedTextStillBeforeCaret: nil,
            sameElementStillFocused: nil
        ))
        #expect(DictationController.rewriteMayDelete(
            typedTextStillBeforeCaret: nil,
            sameElementStillFocused: true
        ))
        #expect(!DictationController.rewriteMayDelete(
            typedTextStillBeforeCaret: nil,
            sameElementStillFocused: false
        ))
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
        // The decision itself, where "nothing published" is reachable. A test cannot
        // make the live system stop publishing a focused element on demand.
        #expect(TextInjector.focusedElementVerdict(focused: nil, expected: unrelated) == nil)
        #expect(TextInjector.focusedElementVerdict(focused: unrelated, expected: unrelated) == true)
        let other = AXUIElementCreateApplication(
            try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier) &+ 20_000
        )
        #expect(TextInjector.focusedElementVerdict(focused: other, expected: unrelated) == false)

        // An application element is never the focused *text* element, so the live query
        // is either nil or false — never true — and the collapsing wrapper must agree
        // with the tri-state source it is built on.
        #expect(TextInjector.focusedElementMatches(unrelated) != true)
        #expect(TextInjector.elementIsStillFocused(unrelated)
                == (TextInjector.focusedElementMatches(unrelated) == true))
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
