import AppKit
import ApplicationServices
import CoreGraphics
import OSLog

private let log = Logger(subsystem: "com.mingyili.Whisper", category: "inject")

/// Types text into whatever app currently has focus.
///
/// The hard part: while dictating, the trigger modifier (e.g. right ⌘) is physically
/// held down. A naively posted key event inherits that flag, so typing "n" would fire
/// ⌘N instead of inserting a character. Two defenses are used together:
///
///  1. events are created from a `.privateState` source, which keeps its own modifier
///     state instead of mirroring the hardware, and
///  2. every event's `flags` is explicitly cleared to zero.
@MainActor
enum TextInjector {
    /// `CGEvent.keyboardSetUnicodeString` is only reliable for short runs, so long
    /// strings are posted as several events.
    private static let maxUnitsPerEvent = 16

    private static let deleteKeyCode: CGKeyCode = 51
    private static let vKeyCode: CGKeyCode = 9

    private static var source: CGEventSource? = {
        let src = CGEventSource(stateID: .privateState)
        // Do not let our synthetic events be coalesced with hardware key state.
        src?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        return src
    }()

    // MARK: - Typing

    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        for chunk in chunked(Array(text.utf16)) {
            postUnicode(chunk)
        }
    }

    /// Deletes `count` characters to the left of the caret. Counted in grapheme
    /// clusters so that CJK text and emoji delete one visible character per press.
    static func deleteBackward(count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            postKey(deleteKeyCode)
        }
    }

    // MARK: - Pasting

    /// A clipboard restore that has been scheduled but not yet executed. Later
    /// sentences are posted as Unicode behind its still-unacknowledged ⌘V, so they
    /// cannot overwrite the data that first paste may still need.
    private struct PasteAnchor {
        let element: AXUIElement
        let targetPID: pid_t
        let selectionBeforePaste: CFRange
    }

    private struct PendingRestore {
        let id: UUID
        let changeCount: Int
        let targetPID: pid_t
        let pastedText: String
        let anchor: PasteAnchor?
        var queuedTypedText = ""
        var deferredClipboardText = ""
        let task: Task<Void, Never>
    }

    private static var pendingRestore: PendingRestore?

    /// A ⌘V whose consumption could not be proven and whose target did not even
    /// answer an AX probe — i.e. very likely still queued inside a hung app. As
    /// long as the pasteboard still holds that paste's data (the change count
    /// matches), nothing may overwrite the board: the queued ⌘V would deliver
    /// the *new* contents into the stalled document when it finally drains. The
    /// 3 s restore window is no bound on how long an app can beachball, so this
    /// outlives `pendingRestore` and is re-checked lazily on the next write.
    /// `fallbackText` collects text that was aimed at the hung target with no
    /// confirmation — it gets its clipboard slot the moment the hold lifts.
    private struct UnprovenPaste {
        let changeCount: Int
        let targetPID: pid_t
        var fallbackText: String
    }
    private static var unprovenPaste: UnprovenPaste?

    private enum UnprovenPasteDisposition {
        /// No hold in effect; write freely.
        case free
        /// A hung app may still hold an unconsumed ⌘V against the current
        /// board contents; nothing may rewrite the board.
        case held
        /// The hold lifted just now; the associated text was never confirmed
        /// at its target and deserves a clipboard slot with the caller's cycle.
        case released(fallbackText: String)
    }

    /// Re-checks the hold lazily for a caller about to rewrite the board.
    /// Clears itself once the board moved on or the target proves alive.
    private static func unprovenPasteDisposition(
        _ pasteboard: NSPasteboard
    ) -> UnprovenPasteDisposition {
        guard let unproven = unprovenPaste else { return .free }
        guard pasteboard.changeCount == unproven.changeCount else {
            // Someone else moved the board on; whatever the stalled ⌘V pastes
            // now is out of our hands either way — and surfacing stale fallback
            // text would clobber that newer content.
            unprovenPaste = nil
            return .free
        }
        guard !targetSeemsResponsive(unproven.targetPID) else {
            unprovenPaste = nil
            return .released(fallbackText: unproven.fallbackText)
        }
        return .held
    }

    /// Puts `text` on the pasteboard and sends ⌘V, restoring the previous contents after.
    static func paste(_ text: String, targetPID: pid_t) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general

        if var pending = pendingRestore,
           pasteboard.changeCount == pending.changeCount {
            // Do not overwrite a clipboard that an earlier synthetic ⌘V may not have
            // consumed yet. Queue this sentence as Unicode events behind that ⌘V;
            // CGEvent ordering preserves both sentences even when the target's main
            // thread is stalled. Extend the proof suffix so the original clipboard
            // can still be restored after both arrive.
            // The focus probe below can block for its full 0.2 s AX timeout —
            // time enough to ⌘Tab away — so the frontmost app is re-checked
            // immediately before any keystroke is posted.
            if pending.targetPID == targetPID,
               anchorElementIsStillFocused(pending.anchor),
               NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
                pending.queuedTypedText += text
                pendingRestore = pending
                type(text)
            } else {
                // The Unicode fallback is aimed at another app — or at a different
                // control in the same app (the anchor element lost focus). The
                // first paste's AX proof runs against that element, so folding
                // this sentence into its expected suffix would make even the
                // first sentence unprovable. Keep a clipboard fallback attached
                // to the pending operation instead, applied once that proof
                // settles, in case this target rejects synthetic text.
                pending.deferredClipboardText += text
                pendingRestore = pending
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
                    type(text)
                }
            }
            return
        }

        var deferredSeed = ""
        switch unprovenPasteDisposition(pasteboard) {
        case .held:
            // A hung app may still hold an unconsumed ⌘V against the current
            // board. Type this sentence instead of re-pasting — event order
            // keeps it behind that ⌘V — and record it as fallback text: if the
            // target rejects synthetic typing, it becomes recoverable from the
            // clipboard the moment the hold lifts.
            unprovenPaste?.fallbackText += text
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
                type(text)
            }
            return
        case .released(let fallbackText):
            // Text typed at the previously hung target was never confirmed.
            // Attach it to this new cycle as its deferred clipboard fallback so
            // it still gets its slot on the board once this paste settles.
            deferredSeed = fallbackText
        case .free:
            break
        }

        pendingRestore?.task.cancel()
        pendingRestore = nil

        let pasteAnchor = capturePasteAnchor(targetPID: targetPID)
        let snapshotChangeCount = pasteboard.changeCount
        let saved = snapshot(pasteboard)
        // Both AX and a full multi-representation clipboard snapshot can block.
        // Revalidate immediately before mutation so a focus switch cannot redirect
        // ⌘V and a clipboard write during either operation cannot be overwritten.
        guard pasteboard.changeCount == snapshotChangeCount else {
            // Someone else wrote the board mid-flight; it must not be clobbered.
            // Keyboard focus is unaffected by that, so fall back to typing while
            // the target is still frontmost rather than dropping the sentence.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
                type(text)
            }
            return
        }
        guard pasteTargetIsStillCurrent(pasteAnchor, targetPID: targetPID) else {
            replaceClipboard(with: text)
            return
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            if let saved { restore(saved, to: pasteboard) }
            type(text)
            return
        }
        let ourChangeCount = pasteboard.changeCount

        postKey(vKeyCode, flags: .maskCommand)

        // There is no acknowledgement for a synthetic ⌘V. Restoring after a fixed
        // delay can therefore race a busy target: it may process the queued key only
        // after the old clipboard is back and paste the wrong thing. Instead, restore
        // only after Accessibility proves that this exact text reached the caret.
        // Controls that do not expose ranges simply keep the transcript on the board;
        // that is less tidy, but it cannot silently lose the user's sentence.
        let restoreID = UUID()
        let task = Task { @MainActor in
            for _ in 0..<30 {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard let pending = pendingRestore,
                      pending.id == restoreID else { return }
                // If anything else wrote to the pasteboard in the meantime, that is
                // now what the user expects to paste. Release our possibly-large
                // snapshot instead of retaining it until another dictation.
                guard pasteboard.changeCount == ourChangeCount else {
                    pendingRestore = nil
                    return
                }
                let expected = pending.pastedText + pending.queuedTypedText
                guard pasteWasConsumed(expected, from: pending.anchor) else {
                    continue
                }
                // AX may block for its full messaging timeout. Re-check immediately
                // before writing so clipboard content copied during that call wins.
                guard pasteboard.changeCount == ourChangeCount else {
                    pendingRestore = nil
                    return
                }
                pendingRestore = nil
                if pending.deferredClipboardText.isEmpty {
                    if let saved {
                        restore(saved, to: pasteboard)
                    }
                } else {
                    replaceClipboard(with: pending.deferredClipboardText)
                }
                return
            }
            guard let pending = pendingRestore,
                  pending.id == restoreID else { return }
            // A paste-only control may have consumed the first sentence but rejected
            // the queued Unicode sentences. If the original element/caret proves the
            // paste itself landed, preserve any unconfirmed later text on the board.
            let pastedOnlyWasConsumed = pasteWasConsumed(
                pending.pastedText,
                from: pending.anchor
            )
            guard pasteboard.changeCount == ourChangeCount else {
                pendingRestore = nil
                return
            }
            pendingRestore = nil
            if pastedOnlyWasConsumed {
                let fallback = pending.queuedTypedText + pending.deferredClipboardText
                if fallback.isEmpty {
                    if let saved {
                        restore(saved, to: pasteboard)
                    }
                } else {
                    replaceClipboard(with: fallback)
                }
            } else if targetSeemsResponsive(pending.targetPID) {
                // No AX proof either way, but the target's run loop is alive, so
                // the ⌘V posted seconds ago is no longer queued — it was
                // dequeued, just unprovably (no AX ranges, or the caret moved).
                // The board can move on: hand it to the unconfirmed later text,
                // so a sentence a paste-only control rejected as Unicode stays
                // one manual ⌘V away. Without such text, keep the transcript on
                // the board — "dequeued" is not "inserted", and restoring the
                // old contents would erase its only copy outside history.
                let fallback = pending.queuedTypedText + pending.deferredClipboardText
                if !fallback.isEmpty {
                    replaceClipboard(with: fallback)
                }
            } else {
                // The target is hung, with our ⌘V very likely still queued in
                // it. The board must keep this exact paste until that drains —
                // and the next dictation must not overwrite it either, so the
                // guard outlives this task (`unprovenPasteDisposition`). The
                // unconfirmed later text rides along as fallback and gets its
                // clipboard slot when the hold lifts.
                unprovenPaste = UnprovenPaste(
                    changeCount: ourChangeCount,
                    targetPID: pending.targetPID,
                    fallbackText: pending.queuedTypedText + pending.deferredClipboardText
                )
            }
        }
        pendingRestore = PendingRestore(
            id: restoreID,
            changeCount: ourChangeCount,
            targetPID: targetPID,
            pastedText: text,
            anchor: pasteAnchor,
            deferredClipboardText: deferredSeed,
            task: task
        )
    }

    static func copyToClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        if var pending = pendingRestore,
           pasteboard.changeCount == pending.changeCount {
            // The earlier ⌘V may still read this board. Defer the replacement until
            // its original element/caret proves consumption; if that cannot be
            // proven, the earlier transcript remains available and this one remains
            // recoverable from history instead of corrupting the pending paste.
            pending.deferredClipboardText += text
            pendingRestore = pending
            return
        }
        switch unprovenPasteDisposition(pasteboard) {
        case .held:
            // Rewriting the board would feed this text to the ⌘V still queued in
            // the hung app. Keep it as fallback for when the hold lifts.
            unprovenPaste?.fallbackText += text
            log.warning("clipboard is held by an unproven paste into a hung app; deferring copy")
            return
        case .released, .free:
            // An explicit copy is the newest intent for the board; any released
            // fallback text stays recoverable from history.
            break
        }
        pendingRestore?.task.cancel()
        pendingRestore = nil
        replaceClipboard(with: text)
    }

    /// The focused-element fetch on the system-wide element is forwarded to the
    /// frontmost app and blocks for the global default (~6 s) if that app is hung —
    /// long enough for the OS to disable our event tap and abort a dictation in
    /// progress. Cap it like every per-element call that follows.
    private static func systemWideElement() -> AXUIElement {
        let system = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(system, 0.2)
        return system
    }

    /// Whether the element the pending paste's proof is anchored to still has
    /// keyboard focus. A `nil` anchor carries no element to compare against, so
    /// the caller's PID check is the best available discriminator.
    private static func anchorElementIsStillFocused(_ anchor: PasteAnchor?) -> Bool {
        guard let anchor else { return true }
        return elementIsStillFocused(anchor.element)
    }

    /// The AX element that currently has keyboard focus in the app identified by
    /// `expectedPID`, or nil when it cannot be determined or belongs elsewhere.
    static func captureFocusedElement(expectedPID: pid_t) -> AXUIElement? {
        let system = systemWideElement()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else { return nil }
        let focused = focusedValue as! AXUIElement
        _ = AXUIElementSetMessagingTimeout(focused, 0.2)
        var actualPID = pid_t()
        guard AXUIElementGetPid(focused, &actualPID) == .success,
              actualPID == expectedPID else {
            return nil
        }
        return focused
    }

    /// Whether `element` is still the focused UI element system-wide.
    static func elementIsStillFocused(_ element: AXUIElement) -> Bool {
        let system = systemWideElement()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else {
            return false
        }
        return CFEqual(focusedValue as! AXUIElement, element)
    }

    /// Whether the app is currently servicing requests. AX messages are handled
    /// on the target's main run loop, so any reply other than a timeout means
    /// that loop is alive — and a ⌘V posted *before* this probe has almost
    /// certainly been dequeued by now. `.cannotComplete` is the timeout result a
    /// hung app produces.
    private static func targetSeemsResponsive(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &value)
            != .cannotComplete
    }

    /// Whether the document still contains exactly the text we previously typed
    /// immediately before its caret. `nil` means the target does not expose enough
    /// Accessibility data to decide; `false` is a positive mismatch.
    static func matchesTextImmediatelyBeforeCaret(
        _ text: String,
        expectedProcessIdentifier: pid_t? = nil
    ) -> Bool? {
        guard !text.isEmpty else { return true }

        let system = systemWideElement()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else {
            return nil
        }
        let focused = focusedValue as! AXUIElement
        if let expectedProcessIdentifier {
            var actualProcessIdentifier = pid_t()
            guard AXUIElementGetPid(focused, &actualProcessIdentifier) == .success,
                  actualProcessIdentifier == expectedProcessIdentifier else {
                return false
            }
        }
        _ = AXUIElementSetMessagingTimeout(focused, 0.2)

        var selectionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &selectionValue
        ) == .success, let selectionValue,
              CFGetTypeID(selectionValue) == AXValueGetTypeID() else {
            return nil
        }

        var selection = CFRange()
        guard AXValueGetValue(selectionValue as! AXValue, .cfRange, &selection) else {
            return nil
        }
        // Backspace would delete the selection rather than our suffix.
        guard selection.length == 0 else { return false }

        let expectedLength = text.utf16.count
        guard selection.location >= expectedLength else { return false }
        var requested = CFRange(
            location: selection.location - expectedLength,
            length: expectedLength
        )
        guard let requestedValue = AXValueCreate(.cfRange, &requested) else { return nil }

        var actualValue: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            focused,
            kAXStringForRangeParameterizedAttribute as CFString,
            requestedValue,
            &actualValue
        )
        guard result == .success, let actual = actualValue as? String else {
            return nil
        }
        // This parameterized attribute is required to return exactly the requested
        // range. Accepting a suffix of a larger response lets a broken AX control
        // "prove" text at some unrelated location and makes the following backspaces
        // destructive.
        return actual.utf16.count == expectedLength && actual == text
    }

    // MARK: - Event plumbing

    private static func snapshot(
        _ pasteboard: NSPasteboard
    ) -> [[NSPasteboard.PasteboardType: Data]]? {
        if pasteboard.accessBehavior == .alwaysDeny { return nil }
        guard let items = pasteboard.pasteboardItems else { return nil }

        var snapshot: [[NSPasteboard.PasteboardType: Data]] = []
        snapshot.reserveCapacity(items.count)
        for item in items {
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                // A partial backup is not safe to restore: it would silently strip
                // representations such as rich text, files or promised data.
                guard let data = item.data(forType: type) else { return nil }
                copy[type] = data
            }
            snapshot.append(copy)
        }
        return snapshot
    }

    private static func restore(
        _ snapshot: [[NSPasteboard.PasteboardType: Data]],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private static func replaceClipboard(with text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func capturePasteAnchor(targetPID: pid_t) -> PasteAnchor? {
        let system = systemWideElement()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else {
            return nil
        }
        let focused = focusedValue as! AXUIElement
        _ = AXUIElementSetMessagingTimeout(focused, 0.2)

        var actualPID = pid_t()
        guard AXUIElementGetPid(focused, &actualPID) == .success,
              actualPID == targetPID else {
            return nil
        }

        var selectionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &selectionValue
        ) == .success, let selectionValue,
              CFGetTypeID(selectionValue) == AXValueGetTypeID() else {
            return nil
        }
        var selection = CFRange()
        guard AXValueGetValue(selectionValue as! AXValue, .cfRange, &selection),
              selection.location >= 0 else {
            return nil
        }
        return PasteAnchor(
            element: focused,
            targetPID: targetPID,
            selectionBeforePaste: selection
        )
    }

    private static func pasteWasConsumed(_ text: String, from anchor: PasteAnchor?) -> Bool {
        guard let anchor, !text.isEmpty else { return false }

        let system = systemWideElement()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else {
            return false
        }
        let focused = focusedValue as! AXUIElement
        guard CFEqual(focused, anchor.element) else { return false }
        _ = AXUIElementSetMessagingTimeout(focused, 0.2)

        var actualPID = pid_t()
        guard AXUIElementGetPid(focused, &actualPID) == .success,
              actualPID == anchor.targetPID else {
            return false
        }

        var selectionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &selectionValue
        ) == .success, let selectionValue,
              CFGetTypeID(selectionValue) == AXValueGetTypeID() else {
            return false
        }
        var selection = CFRange()
        guard AXValueGetValue(selectionValue as! AXValue, .cfRange, &selection),
              selection.length == 0,
              selection.location == anchor.selectionBeforePaste.location + text.utf16.count else {
            return false
        }

        var requested = CFRange(
            location: selection.location - text.utf16.count,
            length: text.utf16.count
        )
        guard let requestedValue = AXValueCreate(.cfRange, &requested) else { return false }
        var actualValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused,
            kAXStringForRangeParameterizedAttribute as CFString,
            requestedValue,
            &actualValue
        ) == .success, let actual = actualValue as? String else {
            return false
        }
        return actual.utf16.count == text.utf16.count && actual == text
    }

    private static func pasteTargetIsStillCurrent(
        _ anchor: PasteAnchor?,
        targetPID: pid_t
    ) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            return false
        }
        // Some controls expose no AX selection. PID validation still prevents a
        // cross-application paste; lack of an anchor merely disables restoration.
        guard let anchor else { return true }

        let system = systemWideElement()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else {
            return false
        }
        let focused = focusedValue as! AXUIElement
        guard CFEqual(focused, anchor.element) else { return false }
        _ = AXUIElementSetMessagingTimeout(focused, 0.2)

        var actualPID = pid_t()
        guard AXUIElementGetPid(focused, &actualPID) == .success,
              actualPID == targetPID else {
            return false
        }
        var selectionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &selectionValue
        ) == .success, let selectionValue,
              CFGetTypeID(selectionValue) == AXValueGetTypeID() else {
            return false
        }
        var selection = CFRange()
        guard AXValueGetValue(selectionValue as! AXValue, .cfRange, &selection) else {
            return false
        }
        return selection.location == anchor.selectionBeforePaste.location
            && selection.length == anchor.selectionBeforePaste.length
    }

    private static func postUnicode(_ units: [UniChar]) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }

        var buffer = units
        for event in [down, up] {
            event.flags = []  // critical: drop the held ⌘/⌥ so this stays plain text
            event.setIntegerValueField(.eventSourceUserData, value: kWhisperSyntheticMarker)
            event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }

        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: kWhisperSyntheticMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private static func chunked(_ units: [UniChar]) -> [[UniChar]] {
        guard units.count > maxUnitsPerEvent else { return [units] }
        var result: [[UniChar]] = []
        var index = 0
        while index < units.count {
            var end = min(index + maxUnitsPerEvent, units.count)
            // Never split a surrogate pair across two events.
            if end < units.count, isHighSurrogate(units[end - 1]) { end -= 1 }
            result.append(Array(units[index..<end]))
            index = end
        }
        return result
    }

    private static func isHighSurrogate(_ unit: UniChar) -> Bool {
        (0xD800...0xDBFF).contains(unit)
    }
}
