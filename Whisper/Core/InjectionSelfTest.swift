import AppKit
import ApplicationServices
import OSLog

private let log = Logger(subsystem: "com.mingyili.Whisper", category: "selftest")

/// Exercises the real injection path against whatever app is in front, and says what
/// each proof answered.
///
/// It exists because the assumptions this path rests on are assumptions about *other
/// apps* — whether a control publishes a system-wide focused element, whether that
/// element stays comparable across a second, whether it reports a selected range — and
/// no unit test can answer them. A full green suite shipped a build that sent every
/// sentence to the clipboard instead of the document, twice, because those questions
/// were answered by reasoning rather than measurement.
///
/// Inert unless `WHISPER_INJECTION_SELFTEST` names a delay in seconds:
///
///     open -n --env WHISPER_INJECTION_SELFTEST=3 /Applications/Whisper.app
///
/// The delay is there to bring the app under test to the front first. Nothing else in
/// this process starts — no hot key, no audio, no socket — so it cannot disturb the
/// copy the user is running. It types a marker, checks, then deletes exactly what it
/// typed; run it against a scratch document, not real work.
@MainActor
enum InjectionSelfTest {
    private static let marker = "WHISPERPROBE"
    private static let pasteMarker = "WHISPERPASTE"

    static var requestedDelay: TimeInterval? {
        ProcessInfo.processInfo.environment["WHISPER_INJECTION_SELFTEST"].flatMap(Double.init)
    }

    static func run(after delay: TimeInterval) {
        Task { @MainActor in
            await wait(delay)
            await probe()
            // One shot. Leaving the process alive would leave a second menu-bar
            // instance behind for every run.
            await wait(1)
            NSApp.terminate(nil)
        }
    }

    /// The second sentence arriving while the first paste's clipboard restore is still
    /// pending. Reachable in normal use only with 边说边出字 off and two sentences landing
    /// within the 3 s restore window, which is hard to hit deliberately and impossible to
    /// hit at all without speaking — so it is driven directly here.
    private static func probeQueuedPaste(name: String, pid: pid_t) async {
        let sentinel = "ORIGINALCLIP"
        let first = "QPASTEONE"
        let second = "QPASTETWO"
        // Reported so a leftover from an earlier run cannot be read as this run's
        // result — which is exactly how the first reading of this probe went wrong.
        report("app=\(name) queuedPaste tailBefore=\(documentTail(pid: pid))")
        TextInjector.copyToClipboard(sentinel)
        TextInjector.paste(first, targetPID: pid)
        // Well inside the restore window: the second paste must find the first still
        // pending rather than a settled board.
        await wait(0.3)
        TextInjector.paste(second, targetPID: pid)
        // Past the window, so any restore has had its chance.
        await wait(4.0)

        let both = TextInjector.matchesTextImmediatelyBeforeCaret(
            first + second,
            expectedProcessIdentifier: pid
        )
        let board = NSPasteboard.general.string(forType: .string) ?? ""
        report("""
            app=\(name) queuedPaste bothInOrder=\(describe(both)) \
            firstOnly=\(describe(TextInjector.matchesTextImmediatelyBeforeCaret(first, expectedProcessIdentifier: pid))) \
            secondOnly=\(describe(TextInjector.matchesTextImmediatelyBeforeCaret(second, expectedProcessIdentifier: pid))) \
            reversed=\(describe(TextInjector.matchesTextImmediatelyBeforeCaret(second + first, expectedProcessIdentifier: pid))) \
            docTail=\(documentTail(pid: pid)) \
            clipboard=\(board == sentinel ? "restored" : "left as \(board)")
            """)
        if both == true {
            TextInjector.deleteBackward(count: (first + second).count)
        }
        TextInjector.copyToClipboard("")
    }

    private static func probe() async {
        guard Permissions.hasAccessibility else {
            report("accessibility=denied — this copy cannot post events; nothing measured")
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            report("no foreign frontmost app; bring the app under test to the front first")
            return
        }
        let name = front.localizedName ?? "?"
        let pid = front.processIdentifier
        // Refuse to type into anything but the app this run was aimed at. The probe
        // writes into a real document; picking whatever happens to be in front when a
        // launch is a second late is how it would land in somebody's work.
        if let expected = ProcessInfo.processInfo.environment["WHISPER_SELFTEST_APP"],
           name != expected {
            report("frontmost is \(name), expected \(expected); refusing to type")
            return
        }

        if ProcessInfo.processInfo.environment["WHISPER_SELFTEST_MODE"] == "queuedpaste" {
            await probeQueuedPaste(name: name, pid: pid)
            return
        }

        // 1. The capture every utterance starts with. The element's role is logged
        //    because "no range" means two different things: a control that genuinely
        //    does not publish one, and having grabbed the window instead of the field.
        let target = TextInjector.captureTarget(expectedPID: pid)
        report("""
            app=\(name) axTarget=\(target == nil ? "NONE (kAXErrorNoValue class)" : "ok") \
            role=\(target.map { axRole(of: $0.element) } ?? "-") \
            axRange=\(target?.selection == nil ? "none" : "yes")
            """)

        // 2. The live-delta gate, on the same evidence a real utterance has.
        let liveGate = target.map(TextInjector.targetIsStillFocused) ?? true
        report("app=\(name) liveInjectionGate=\(liveGate ? "CONTINUE" : "ABANDON→clipboard")")

        // 3. Type the marker the way a delta is typed, then ask the destructive
        //    rewrite's proofs about it.
        TextInjector.type(marker)
        await wait(0.5)

        let inserted = marker.utf16.count
        let beforeCaret = TextInjector.matchesTextImmediatelyBeforeCaret(
            marker,
            expectedProcessIdentifier: pid
        )
        let selectionProven = target.map {
            TextInjector.targetSelectionIsStillCurrent($0, insertedUTF16Count: inserted)
        }
        report("""
            app=\(name) typed=\(marker) beforeCaret=\(describe(beforeCaret)) \
            selectionProof=\(describe(selectionProven)) \
            rewriteWouldRun=\(beforeCaret == true && (selectionProven ?? true))
            """)

        TextInjector.deleteBackward(count: marker.count)
        await wait(0.3)

        // 4. The other output mode: 边说边出字 off goes through paste.
        let boardBefore = NSPasteboard.general.changeCount
        TextInjector.paste(pasteMarker, targetPID: pid)
        await wait(0.8)
        let landed = TextInjector.matchesTextImmediatelyBeforeCaret(
            pasteMarker,
            expectedProcessIdentifier: pid
        )
        report("""
            app=\(name) pasteLanded=\(describe(landed)) \
            boardTouched=\(NSPasteboard.general.changeCount != boardBefore)
            """)
        if landed == true {
            TextInjector.deleteBackward(count: pasteMarker.count)
        }
    }

    /// The literal end of the focused control's text, so a failed proof can be read
    /// as "nothing arrived" or "this arrived instead" rather than just "false".
    private static func documentTail(pid: pid_t) -> String {
        guard let target = TextInjector.captureTarget(expectedPID: pid) else { return "?" }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            target.element,
            kAXValueAttribute as CFString,
            &value
        ) == .success, let text = value as? String else {
            return "unreadable"
        }
        return "[" + String(text.suffix(40)).replacingOccurrences(of: "\n", with: "⏎") + "]"
    }

    private static func axRole(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        ) == .success, let role = value as? String else {
            return "?"
        }
        return role
    }

    /// Yields the main thread rather than holding it. Everything being measured here —
    /// the clipboard restore, the delivery proof, the deferred fallback — runs inside a
    /// `Task { @MainActor }` that awaits, and the main actor cannot service that task
    /// while this probe occupies the thread. `usleep` and a nested
    /// `RunLoop.run(until:)` were both tried and both starve it; the probe then reports
    /// "the clipboard was never restored" about a restore it prevented from running.
    private static func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func describe(_ value: Bool?) -> String {
        guard let value else { return "unknown" }
        return value ? "true" : "false"
    }

    /// Both channels on purpose: the log survives, and stdout is what the harness
    /// launching this reads without waiting on the log store.
    private static func report(_ line: String) {
        log.info("\(line, privacy: .public)")
        FileHandle.standardError.write(Data("SELFTEST \(line)\n".utf8))
    }
}
