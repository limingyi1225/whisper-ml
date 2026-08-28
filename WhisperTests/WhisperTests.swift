import DictationKit
import AppKit
import Foundation
import Sparkle
import Testing
@testable import Whisper

// MARK: - Software updates

@Suite struct UpdateConfigurationTests {
    @Test func updateFeedIsSecureAndArchivesRequireTheExpectedSigningKey() {
        let info = Bundle.main.infoDictionary
        let feedURL = (info?["SUFeedURL"] as? String).flatMap(URL.init(string:))

        #expect(feedURL?.scheme == "https")
        #expect(feedURL?.host == "raw.githubusercontent.com")
        #expect(feedURL?.path == "/limingyi1225/whisper-ml/main/updates/appcast.xml")
        #expect((info?["SUPublicEDKey"] as? String)?.isEmpty == false)
        #expect(info?["SURequireSignedFeed"] as? Bool == true)
        #expect(info?["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(info?["SUEnableAutomaticChecks"] as? Bool == false)
        #expect(info?["SUAutomaticallyUpdate"] as? Bool == false)
    }

    @Test func updateVersionsAreMachineComparable() {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String
        let buildVersion = info?["CFBundleVersion"] as? String

        #expect(shortVersion?.isEmpty == false)
        #expect(buildVersion?.allSatisfy(\.isNumber) == true)
    }

    @Test func unavailableFeedErrorsAreActionableAndLocalized() {
        #expect(AppUpdater.feedErrorMessage(statusCode: 404) == "更新源尚未发布")
        #expect(AppUpdater.feedErrorMessage(statusCode: 503) == "暂时无法连接更新服务器")
        #expect(AppUpdater.feedErrorMessage(statusCode: nil) == "暂时无法连接更新服务器")
        #expect(AppUpdater.updateErrorMessage(
            NSError(domain: "SUSparkleErrorDomain", code: 1001)
        ) == "已是最新版本")
    }

    @Test func noUpdateReasonsDistinguishCurrentFromIncompatible() {
        #expect(AppUpdater.noUpdateState(noUpdateError(.onLatestVersion)) == .upToDate)
        #expect(AppUpdater.noUpdateState(noUpdateError(.onNewerThanLatestVersion)) == .upToDate)
        #expect(AppUpdater.noUpdateState(noUpdateError(.systemIsTooOld)) ==
            .failure("有新版本，但需要更高版本的 macOS"))
        #expect(AppUpdater.noUpdateState(noUpdateError(.systemIsTooNew)) ==
            .failure("新版本暂不支持当前 macOS"))
        #expect(AppUpdater.noUpdateState(noUpdateError(.hardwareDoesNotSupportARM64)) ==
            .failure("新版本不支持这台 Mac"))
        #expect(AppUpdater.noUpdateState(NSError(domain: "unexpected", code: 1)) ==
            .failure("检查更新失败，请稍后重试"))
    }

    @Test func onlyTheExplicitSettingsProbeMayDriveInlineStateAndPresentation() {
        #expect(AppUpdater.shouldFinishManualProbe(
            .updateInformation,
            manualProbeInProgress: true
        ))
        #expect(!AppUpdater.shouldFinishManualProbe(
            .updatesInBackground,
            manualProbeInProgress: true
        ))
        #expect(!AppUpdater.shouldFinishManualProbe(
            .updates,
            manualProbeInProgress: true
        ))
        #expect(!AppUpdater.shouldFinishManualProbe(
            .updateInformation,
            manualProbeInProgress: false
        ))
    }

    @Test @MainActor func preparedUpdateCanDriveTheSharedRestartAction() {
        let updater = AppUpdater()
        var installationWasRequested = false

        updater.prepareUpdateForTesting(version: "2.0") {
            installationWasRequested = true
        }

        #expect(updater.preparedUpdateVersion == "2.0")
        #expect(!updater.isInstallingPreparedUpdate)

        updater.installPreparedUpdate()

        #expect(installationWasRequested)
        #expect(updater.isInstallingPreparedUpdate)
    }

    @Test @MainActor func availableUpdateStartsWithoutASecondUpdateWindow() {
        let updater = AppUpdater()
        var downloadWasRequested = false

        updater.makeUpdateAvailableForTesting(version: "2.0") {
            downloadWasRequested = true
        }

        #expect(updater.availableUpdateVersion == "2.0")
        #expect(updater.preparedUpdateVersion == nil)
        #expect(!updater.isDownloadingUpdate)

        updater.installAvailableUpdate()

        #expect(downloadWasRequested)
        #expect(updater.isDownloadingUpdate)
    }

    @Test @MainActor func downloadProgressIsBounded() {
        let updater = AppUpdater()
        updater.makeUpdateAvailableForTesting(version: "2.0") {}

        updater.updateDownloadProgressForTesting(expected: 100, received: [30, 90])

        #expect(updater.isDownloadingUpdate)
        #expect(updater.downloadProgress == 1)
    }

    @Test @MainActor func onlyAutomaticUpdatesUseSparklesNativeWindow() {
        #expect(!AppUpdater.shouldUseStandardUI(userInitiated: true))
        #expect(AppUpdater.shouldUseStandardUI(userInitiated: false))
    }

    private func noUpdateError(_ reason: SPUNoUpdateFoundReason) -> NSError {
        NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.noUpdateError.rawValue),
            userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue)]
        )
    }
}

// MARK: - Focus-aware HUD visibility

@Suite struct FocusedInputTests {
    @Test func recognizesEditableTextControls() {
        #expect(FocusedInputMonitor.isEditableText(
            role: kAXTextFieldRole as String,
            subrole: nil,
            enabled: true,
            valueIsSettable: true,
            selectionIsSettable: false
        ))
        #expect(FocusedInputMonitor.isEditableText(
            role: kAXTextAreaRole as String,
            subrole: nil,
            enabled: true,
            valueIsSettable: false,
            selectionIsSettable: true
        ))
        #expect(FocusedInputMonitor.isEditableText(
            role: "AXWebArea",
            subrole: nil,
            enabled: true,
            valueIsSettable: true,
            selectionIsSettable: false
        ))
    }

    @Test func rejectsReadOnlyDisabledAndSecureText() {
        #expect(!FocusedInputMonitor.isEditableText(
            role: kAXStaticTextRole as String,
            subrole: nil,
            enabled: true,
            valueIsSettable: false,
            selectionIsSettable: true
        ))
        #expect(!FocusedInputMonitor.isEditableText(
            role: kAXTextFieldRole as String,
            subrole: nil,
            enabled: false,
            valueIsSettable: false,
            selectionIsSettable: false
        ))
        #expect(!FocusedInputMonitor.isEditableText(
            role: kAXTextFieldRole as String,
            subrole: kAXSecureTextFieldSubrole as String,
            enabled: true,
            valueIsSettable: true,
            selectionIsSettable: true
        ))
        #expect(!FocusedInputMonitor.isEditableText(
            role: kAXSliderRole as String,
            subrole: nil,
            enabled: true,
            valueIsSettable: true,
            selectionIsSettable: false
        ))
        #expect(!FocusedInputMonitor.isEditableText(
            role: kAXGroupRole as String,
            subrole: nil,
            enabled: true,
            valueIsSettable: true,
            selectionIsSettable: true
        ))
    }

    @Test func recognizesWritableTextWhenWordMisreportsDisabled() {
        #expect(FocusedInputMonitor.isEditableText(
            role: kAXTextAreaRole as String,
            subrole: nil,
            enabled: false,
            valueIsSettable: true,
            selectionIsSettable: true
        ))
    }

    @Test func onlyContainersCanSearchForNestedEditors() {
        #expect(FocusedInputMonitor.shouldSearchEditableDescendants(
            of: kAXSplitGroupRole as String
        ))
        #expect(FocusedInputMonitor.shouldSearchEditableDescendants(
            of: kAXScrollAreaRole as String
        ))
        #expect(FocusedInputMonitor.shouldSearchEditableDescendants(
            of: "AXLayoutItem"
        ))
        #expect(!FocusedInputMonitor.shouldSearchEditableDescendants(
            of: kAXButtonRole as String
        ))
        #expect(!FocusedInputMonitor.shouldSearchEditableDescendants(
            of: kAXStaticTextRole as String
        ))
    }

    @Test func officeEditModeKeysTriggerFocusRechecksWithoutPollingOrdinaryTyping() {
        #expect(FocusedInputMonitor.shouldRefreshAfterKeyDown(
            keyCode: 0,
            hasFocusedEditableInput: false
        ))
        #expect(FocusedInputMonitor.shouldRefreshAfterKeyDown(
            keyCode: 53,
            hasFocusedEditableInput: true
        ))
        #expect(FocusedInputMonitor.shouldRefreshAfterKeyDown(
            keyCode: 120,
            hasFocusedEditableInput: true
        ))
        #expect(!FocusedInputMonitor.shouldRefreshAfterKeyDown(
            keyCode: 0,
            hasFocusedEditableInput: true
        ))
    }

    @Test func opaqueEditorsUseAnExplicitAppWideFallback() {
        #expect(FocusedInputMonitor.usesAppWideInputFallback(
            bundleIdentifier: "com.microsoft.Powerpoint"
        ))
        #expect(FocusedInputMonitor.usesAppWideInputFallback(
            bundleIdentifier: "com.tencent.xinWeChat"
        ))
        #expect(FocusedInputMonitor.usesAppWideInputFallback(
            bundleIdentifier: "com.anthropic.claudefordesktop"
        ))
        #expect(FocusedInputMonitor.usesAppWideInputFallback(
            bundleIdentifier: "com.openai.codex"
        ))
        #expect(FocusedInputMonitor.usesAppWideInputFallback(
            bundleIdentifier: "com.apple.Safari"
        ))
        #expect(!FocusedInputMonitor.usesAppWideInputFallback(
            bundleIdentifier: "com.microsoft.Word"
        ))
        #expect(!FocusedInputMonitor.usesAppWideInputFallback(bundleIdentifier: nil))
    }

    @Test func spotlightPanelsCountAsAnInputSurfaceOfTheirOwn() {
        // Spotlight is never the frontmost application, so the only way its search
        // field is ever seen is by asking the process that draws the panel.
        #expect(FocusedInputMonitor.isOverlayInputSurface(
            bundleIdentifier: "com.apple.campo"
        ))
        #expect(FocusedInputMonitor.isOverlayInputSurface(
            bundleIdentifier: "com.apple.Spotlight"
        ))
        // Voice Siri lives in a process of its own and publishes no text field; the
        // dictation pill has nothing to offer it.
        #expect(!FocusedInputMonitor.isOverlayInputSurface(
            bundleIdentifier: "com.apple.Siri"
        ))
        #expect(!FocusedInputMonitor.isOverlayInputSurface(bundleIdentifier: nil))
    }

    @Test func spotlightSearchFieldReadsAsEditable() {
        // What Spotlight's panel actually reports when it is up.
        #expect(FocusedInputMonitor.isEditableText(
            role: kAXTextFieldRole as String,
            subrole: "AXSearchField",
            enabled: true,
            valueIsSettable: true,
            selectionIsSettable: true
        ))
    }

    @Test func onlyAnAnsweredEmptyFocusAsksForAnAccessibilityTree() {
        // What Chrome replies before its page tree exists: it answers, and the answer
        // is that nothing is focused.
        #expect(FocusedInputMonitor.publishesNoFocus(axError: .noValue))
        // An app that does not implement the attribute has no lazy tree to wake, so
        // declaring to it could only ever be noise.
        #expect(!FocusedInputMonitor.publishesNoFocus(axError: .attributeUnsupported))
        // A timeout is not an answer. Reading one as "this app publishes no tree"
        // would declare an assistive client to any app that was merely busy for a
        // moment — Word mid-save, Xcode mid-index — and that declaration is not
        // withdrawn for the rest of the app's life.
        #expect(!FocusedInputMonitor.publishesNoFocus(axError: .cannotComplete))
        #expect(!FocusedInputMonitor.publishesNoFocus(axError: .failure))
        #expect(!FocusedInputMonitor.publishesNoFocus(axError: .apiDisabled))
    }

    @Test func accessibilityRequestsAreRateLimitedOnOneClockNotPerApp() {
        let start = Date()
        #expect(FocusedInputMonitor.shouldSendAccessibilityRequest(
            lastSentAt: nil,
            now: start
        ))
        #expect(!FocusedInputMonitor.shouldSendAccessibilityRequest(
            lastSentAt: start,
            now: start.addingTimeInterval(0.5)
        ))
        // Switching apps must not reset the interval: a per-app timestamp let a
        // ⌘-Tab between two apps that both publish nothing send the blocking
        // main-thread call on every single switch.
        #expect(FocusedInputMonitor.shouldSendAccessibilityRequest(
            lastSentAt: start,
            now: start.addingTimeInterval(2)
        ))
    }

    @Test func notificationObserversStillReceivePeriodicHealthProbes() {
        #expect(FocusedInputMonitor.shouldRunHealthProbe(
            receivesFocusNotifications: false,
            healthTick: 1
        ))
        #expect(!FocusedInputMonitor.shouldRunHealthProbe(
            receivesFocusNotifications: true,
            healthTick: 1
        ))
        #expect(FocusedInputMonitor.shouldRunHealthProbe(
            receivesFocusNotifications: true,
            healthTick: 2
        ))
    }

    @Test func malformedAXValuesAreRejectedBeforeElementConversion() {
        let malformedValue = "not an accessibility element" as CFString
        #expect(FocusedInputMonitor.checkedAXElement(from: malformedValue) == nil)

        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        #expect(FocusedInputMonitor.checkedAXElement(from: application) != nil)
    }

    @Test func childReadsNeverExceedTraversalCapacityOrPageSize() {
        #expect(FocusedInputMonitor.boundedChildReadCount(
            reportedChildCount: 50_000,
            queuedElementCount: 1,
            maximumElements: 256,
            pageSize: 64
        ) == 64)
        #expect(FocusedInputMonitor.boundedChildReadCount(
            reportedChildCount: 50_000,
            queuedElementCount: 250,
            maximumElements: 256,
            pageSize: 64
        ) == 6)
        #expect(FocusedInputMonitor.boundedChildReadCount(
            reportedChildCount: 50_000,
            queuedElementCount: 256,
            maximumElements: 256,
            pageSize: 64
        ) == 0)
        #expect(FocusedInputMonitor.boundedChildReadCount(
            reportedChildCount: 3,
            queuedElementCount: 1,
            maximumElements: 256,
            pageSize: 64
        ) == 3)
    }

    @Test func placementCheckLooksForThePanelInTheActiveDesktopsWindows() {
        let windows: [[String: Any]] = [
            [kCGWindowNumber as String: 4001, kCGWindowOwnerName as String: "Dock"],
            [kCGWindowNumber as String: 4002, kCGWindowOwnerName as String: "Whisper"],
        ]

        #expect(RecordingHUDController.containsWindow(number: 4002, in: windows))
        #expect(!RecordingHUDController.containsWindow(number: 4003, in: windows))
        #expect(!RecordingHUDController.containsWindow(number: 4002, in: []))
    }

    /// A lock and wake can strand the pill on whichever desktop was in front when the
    /// lid closed, and re-asserting the collection behaviour does not bring it back —
    /// the repair is a new window. Which is also the repair that can do damage: while
    /// the login window is up every window of ours is legitimately absent, and building
    /// one then would hand the lock screen a pill of its own.
    @Test func aStrandedPillIsRebuiltButNeverOntoTheLockScreen() {
        let now = Date()
        let elsewhere: [[String: Any]] = [
            [kCGWindowNumber as String: 4001, kCGWindowOwnerName as String: "Dock"],
        ]

        #expect(RecordingHUDController.placementRepair(
            screenIsLocked: false,
            onScreenWindows: elsewhere,
            panelWindowNumber: 4002,
            lastRebuiltAt: nil,
            now: now
        ) == .rebuild)

        #expect(RecordingHUDController.placementRepair(
            screenIsLocked: true,
            onScreenWindows: elsewhere,
            panelWindowNumber: 4002,
            lastRebuiltAt: nil,
            now: now
        ) == .none)

        // A pill that is where it should be, and a window list that failed to answer,
        // are both left alone.
        #expect(RecordingHUDController.placementRepair(
            screenIsLocked: false,
            onScreenWindows: elsewhere + [[kCGWindowNumber as String: 4002]],
            panelWindowNumber: 4002,
            lastRebuiltAt: nil,
            now: now
        ) == .none)
        #expect(RecordingHUDController.placementRepair(
            screenIsLocked: false,
            onScreenWindows: [],
            panelWindowNumber: 4002,
            lastRebuiltAt: nil,
            now: now
        ) == .none)
    }

    /// Whatever else is true, the pill must not be torn down and rebuilt once a second:
    /// the check runs every time focus moves into a text field, and a cause we have not
    /// thought of would otherwise restart the animation for as long as it lasted.
    @Test func aRebuildThatDidNotTakeFallsBackToTheCheapNudge() {
        let now = Date()

        #expect(RecordingHUDController.placementRepair(
            screenIsLocked: false,
            onScreenWindows: [[kCGWindowNumber as String: 4001]],
            panelWindowNumber: 4002,
            lastRebuiltAt: now.addingTimeInterval(-1),
            now: now
        ) == .reassertDesktops)

        #expect(RecordingHUDController.placementRepair(
            screenIsLocked: false,
            onScreenWindows: [[kCGWindowNumber as String: 4001]],
            panelWindowNumber: 4002,
            lastRebuiltAt: now.addingTimeInterval(-60),
            now: now
        ) == .rebuild)
    }

    /// The wake delay is longer than the desktop-switch delay for a reason — the login
    /// window comes and goes and the desktops are rebuilt behind it — and unlocking
    /// fires both events at once. Scheduling that let every new request cancel the last
    /// therefore threw away the 1.5s wait chosen for the wake and ran the check 0.4s in,
    /// while the window server was still moving windows around.
    @Test func aLaterPlacementCheckIsNotPulledForwardByAnEarlierOne() {
        let now = Date()
        let wake = now.addingTimeInterval(1.5)
        let spaceSwitch = now.addingTimeInterval(0.4)

        // Nothing pending: whatever is asked for is scheduled.
        #expect(RecordingHUDController.shouldReschedule(pendingDeadline: nil, to: spaceSwitch))

        // The real sequence — wake, then the desktop change it brings with it. The
        // desktop switch must not displace the wake's longer wait.
        #expect(!RecordingHUDController.shouldReschedule(pendingDeadline: wake, to: spaceSwitch))

        // The other order still works: a wake arriving while a desktop switch is pending
        // pushes the check out, because the slower event is the one to wait for.
        #expect(RecordingHUDController.shouldReschedule(pendingDeadline: spaceSwitch, to: wake))

        // An identical deadline is not a reason to rearm and start the wait over.
        #expect(!RecordingHUDController.shouldReschedule(pendingDeadline: wake, to: wake))
    }

    /// 试一下 tells the user that the bar at the bottom of their screen is the pill in
    /// the guide's window. Focus is inside Whisper itself while they read that, which is
    /// exactly the case the focus rule hides the pill for — so without this the sentence
    /// pointed at an empty strip of desktop.
    @Test func theGuidesRehearsalKeepsThePillOnScreenWithoutFocus() {
        #expect(RecordingHUDController.shouldShow(
            phase: .idle,
            hasFocusedEditableInput: false,
            isShowingSettledMark: false,
            isRehearsing: true
        ))
        #expect(!RecordingHUDController.shouldShow(
            phase: .idle,
            hasFocusedEditableInput: false,
            isShowingSettledMark: false,
            isRehearsing: false
        ))
    }

    @Test func idleFollowsFocusWhileActiveStatesStayVisible() {
        #expect(!RecordingHUDController.shouldShow(
            phase: .idle,
            hasFocusedEditableInput: false,
            isShowingSettledMark: false
        ))
        #expect(RecordingHUDController.shouldShow(
            phase: .idle,
            hasFocusedEditableInput: true,
            isShowingSettledMark: false
        ))
        #expect(RecordingHUDController.shouldShow(
            phase: .recording,
            hasFocusedEditableInput: false,
            isShowingSettledMark: false
        ))
        #expect(RecordingHUDController.shouldShow(
            phase: .idle,
            hasFocusedEditableInput: false,
            isShowingSettledMark: true
        ))
        #expect(RecordingHUDController.shouldShow(
            phase: .error("test"),
            hasFocusedEditableInput: false,
            isShowingSettledMark: false
        ))
    }
}

// MARK: - Transcript normalization

@Suite struct NormalizeLeadingSpaceTests {
    @Test func latinKeepsExactlyOneSpace() {
        #expect(DictationController.normalizeLeadingSpace(" hello") == " hello")
        #expect(DictationController.normalizeLeadingSpace("   hello") == " hello")
        #expect(DictationController.normalizeLeadingSpace(" 42度") == " 42度")
    }

    @Test func cjkDropsTheSpace() {
        #expect(DictationController.normalizeLeadingSpace(" 你好") == "你好")
        #expect(DictationController.normalizeLeadingSpace("\t你好") == "你好")
        #expect(DictationController.normalizeLeadingSpace(" ！") == "！")
    }

    @Test func noLeadingSpaceIsUntouched() {
        #expect(DictationController.normalizeLeadingSpace("hello") == "hello")
        #expect(DictationController.normalizeLeadingSpace("你好") == "你好")
        #expect(DictationController.normalizeLeadingSpace("") == "")
    }

    @Test func whitespaceOnlyBecomesEmpty() {
        #expect(DictationController.normalizeLeadingSpace("   ") == "")
    }
}

@Suite struct CommonPrefixLengthTests {
    @Test func countsMatchingGraphemes() {
        #expect(DictationController.commonPrefixLength("abc", "abd") == 2)
        #expect(DictationController.commonPrefixLength("你好吗", "你好啊") == 2)
        #expect(DictationController.commonPrefixLength("same", "same") == 4)
    }

    @Test func emptyAndDisjointAreZero() {
        #expect(DictationController.commonPrefixLength("", "x") == 0)
        #expect(DictationController.commonPrefixLength("a", "b") == 0)
    }

    @Test func multiScalarGraphemesCountAsOne() {
        // 👨‍👩‍👧 is one grapheme built from several scalars; a partial match inside
        // it must not count. deleteBackward deletes per grapheme, so this
        // count is what keeps the backspace count aligned with what the user sees.
        #expect(DictationController.commonPrefixLength("👨‍👩‍👧a", "👨‍👩‍👧b") == 1)
    }

}

@Suite struct IgnoringWhitespaceTests {
    @Test func stripsAllWhitespaceKinds() {
        #expect("a b\tc\nd".ignoringWhitespace == "abcd")
        #expect("你好 世界".ignoringWhitespace == "你好世界")
        #expect("   ".ignoringWhitespace == "")
    }
}

@Suite struct FriendlyMessageTests {
    @Test func translatesKnownServerErrors() {
        #expect(DictationController.friendlyMessage("input buffer too small for commit")
            == "录音太短，没有听到内容")
        #expect(DictationController.friendlyMessage("Incorrect API key provided")
            == "API Key 无效或没有权限")
        #expect(DictationController.friendlyMessage("You exceeded your current quota")
            == "OpenAI 额度不足，去检查账单")
        #expect(DictationController.friendlyMessage("Rate limit reached")
            == "请求太频繁，稍等几秒再试")
    }

    @Test func chineseMessagesPassThroughUntranslated() {
        // Our own messages can legitimately contain English keywords
        // ("还没有设置设备 Token") — keyword matching must not fire on them.
        #expect(
            DictationController.friendlyMessage("还没有设置设备 Token") == "还没有设置设备 Token"
        )
        #expect(DictationController.friendlyMessage("连接中断：quota") == "连接中断：quota")
    }

    @Test func unknownEnglishPassesThrough() {
        #expect(DictationController.friendlyMessage("something unexpected") == "something unexpected")
    }

    @Test func translatesTheGeoBlock() {
        // The message OpenAI actually returns when the request leaves over
        // un-proxied UDP; without this it reaches the pill as raw English.
        #expect(DictationController.friendlyMessage("Country, region, or territory not supported")
            == "OpenAI 不支持这个地区")
    }
}

// MARK: - Keyboard event chunking

@Suite struct ChunkedUnicodeTests {
    @Test func shortRunsPassThroughWhole() {
        let units = Array("hello".utf16)
        #expect(TextInjector.chunked(units) == [units])
        let sixteen = Array(String(repeating: "x", count: 16).utf16)
        #expect(TextInjector.chunked(sixteen) == [sixteen])
    }

    @Test func longRunsSplitWithoutLosingUnits() {
        let units = Array(String(repeating: "水", count: 50).utf16)
        let chunks = TextInjector.chunked(units)
        #expect(chunks.flatMap(\.self) == units)
        #expect(chunks.allSatisfy { $0.count <= 16 && !$0.isEmpty })
    }

    @Test func neverSplitsASurrogatePair() {
        // "𝕏" is a surrogate pair. Place its high surrogate exactly at the
        // 16-unit boundary so a naive split would separate the pair.
        let text = String(repeating: "a", count: 15) + String(repeating: "𝕏", count: 3)
        let units = Array(text.utf16)
        let chunks = TextInjector.chunked(units)
        #expect(chunks.flatMap(\.self) == units)
        for chunk in chunks {
            #expect(!TextInjector.isHighSurrogate(chunk.last!))
        }
    }
}

// MARK: - Realtime protocol plumbing

@Suite struct TurnSequenceTests {
    @Test func parsesTurnScopedEventIDs() {
        let client = RealtimeClient()
        #expect(client.turnSequence(fromClientEventID: "whisper-turn-3-17") == 3)
        #expect(client.turnSequence(fromClientEventID: "whisper-turn-12-1") == 12)
    }

    @Test func rejectsEverythingElse() {
        let client = RealtimeClient()
        // Session-scoped ids and foreign/malformed ids must not be attributed
        // to any turn — a mis-parse here aborts the wrong dictation.
        #expect(client.turnSequence(fromClientEventID: "whisper-session-4") == nil)
        #expect(client.turnSequence(fromClientEventID: "whisper-turn-x-9") == nil)
        #expect(client.turnSequence(fromClientEventID: "evt_abc123") == nil)
        #expect(client.turnSequence(fromClientEventID: nil) == nil)
    }
}

@Suite struct ConnectionLifecycleTests {
    @Test func systemWakeDispatchesRecoveryOnlyWhileObserved() {
        let delegate = AppDelegate()
        var wakeCount = 0
        delegate.systemWakeHandler = { wakeCount += 1 }
        delegate.observeSystemWake()

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(wakeCount == 1)

        // Observer teardown matters for the app lifetime and also proves an old
        // delegate cannot reconnect after a replacement has taken ownership.
        delegate.applicationWillTerminate(Notification(name: .init("test-termination")))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(wakeCount == 1)
    }
}

// MARK: - Polish plausibility guard

@Suite struct PolishPlausibilityTests {
    private let polisher = TranscriptPolisher()

    @Test func emptyResultIsImplausible() {
        #expect(!polisher.isPlausible("", from: "随便说了点什么"))
    }

    @Test func summarySmellIsRejectedForLongInput() {
        let raw = String(repeating: "这是一段相当长的原始转写内容", count: 4)
        #expect(!polisher.isPlausible("好的。", from: raw))
    }

    @Test func replySmellIsRejected() {
        // The model answering the transcript instead of tidying it.
        #expect(!polisher.isPlausible(
            String(repeating: "这是一个膨胀了很多倍的回答", count: 3),
            from: "今天天气怎么样"
        ))
    }

    @Test func shortUtterancesAreExempt() {
        #expect(polisher.isPlausible("对。", from: "对"))
        #expect(polisher.isPlausible("可以。", from: "嗯嗯嗯那个那个我觉得就是嗯可以"))
    }

    @Test func ordinaryCleanupPasses() {
        let raw = "嗯我觉得这个方案就是那个整体上是可以接受的但是有一些细节需要再讨论一下"
        let cleaned = "我觉得这个方案整体上是可以接受的，但有一些细节需要再讨论。"
        #expect(polisher.isPlausible(cleaned, from: raw))
    }

    @Test func transliteratedNamesMayExpand() {
        // The exact output measured from the model. 9 characters becoming 16 is
        // 1.8×, past the plain 1.6× ceiling — rejecting it would hand the user
        // back "凯文和艾米", which is what the name rule exists to fix.
        #expect(polisher.isPlausible("Kevin 和 Amy 明天过来", from: "凯文和艾米明天过来"))
        #expect(polisher.isPlausible("Kevin", from: "凯文"))
    }

    @Test func vocabularyExpansionIsAllowedWithTheList() {
        // A Chinese term that is longer than what was misheard gets no help from
        // the Latin measure; it has to be covered by the list itself.
        #expect(polisher.isPlausible(
            "中国科学技术大学",
            from: "中科大",
            vocabulary: ["中国科学技术大学"]
        ))
        #expect(!polisher.isPlausible("中国科学技术大学", from: "中科大"))
    }

    @Test func slackOnlyCoversTermsThatActuallyCameBack() {
        // A long list must not silently disarm the guard: the reply below contains
        // none of the listed terms, so it gets no slack and stays implausible.
        #expect(!polisher.isPlausible(
            String(repeating: "这是一个膨胀了很多倍的回答", count: 3),
            from: "今天天气怎么样",
            vocabulary: ["Anthropic", "Kubernetes", "TypeScript", "李明一"]
        ))
    }

    @Test func anEnglishReplyStillTripsTheGuard() {
        // Latin slack is capped at roughly the raw length, so the model answering
        // in English cannot buy its way past the ceiling one letter at a time.
        #expect(!polisher.isPlausible(
            "The weather today is quite nice and sunny outside.",
            from: "今天天气怎么样"
        ))
    }
}

// MARK: - Cleanup prompt

@Suite struct PolishInstructionsTests {
    @Test func emptyVocabularyAddsNothing() {
        // Users who never open that box should be running exactly the prompt that
        // was tuned without it.
        #expect(!TranscriptPolisher.instructions(vocabulary: []).contains("常用词汇表"))
    }

    @Test func vocabularyIsListedVerbatimAndIsAdditive() {
        let base = TranscriptPolisher.instructions(vocabulary: [])
        let withTerms = TranscriptPolisher.instructions(vocabulary: ["Kevin", "李明一"])
        #expect(withTerms.hasPrefix(base))
        #expect(withTerms.contains("Kevin"))
        #expect(withTerms.contains("李明一"))
    }

    @Test func properNounsAreNoLongerOffLimits() {
        // The old blanket "never touch names" rule is what made a vocabulary
        // list unusable; if it comes back, the feature silently stops working.
        #expect(!TranscriptPolisher.instructions(vocabulary: ["Kevin"])
            .contains("人名、产品名、专业术语、代码标识符即使看起来奇怪也不要动"))
    }

    @Test func laughterIsProtectedFromTheFillerRule() {
        // Measured: without this line the cleanup model reads 哈哈/嘿嘿 as 口头禅 and
        // deletes it, 3 of 3 runs. The loss is silent — the sentence still reads fine,
        // it just stops sounding like the person who spoke it.
        let base = TranscriptPolisher.instructions(vocabulary: [])
        #expect(base.contains("笑声和语气词"))
        #expect(base.contains("一律保留原样"))
    }

    @Test func transliteratedNameRuleAppliesWithoutAVocabulary() {
        // The name rule is part of the base prompt, not the vocabulary block —
        // an empty list must still turn 艾米 into Amy.
        let base = TranscriptPolisher.instructions(vocabulary: [])
        #expect(base.contains("艾米→Amy"))
        #expect(base.contains("中文名字保持中文"))
    }
}

// MARK: - Vocabulary parsing

@Suite struct VocabularyParsingTests {
    @Test func splitsTrimsAndKeepsOrder() {
        #expect(AppSettings.parseVocabulary("Kevin\n  李明一  \nAnthropic")
            == ["Kevin", "李明一", "Anthropic"])
    }

    @Test func dropsBlanksAndDuplicates() {
        #expect(AppSettings.parseVocabulary("\n\nKevin\n \nKevin\n") == ["Kevin"])
        #expect(AppSettings.parseVocabulary("") == [])
        #expect(AppSettings.parseVocabulary("   \n\t\n") == [])
    }

    @Test func dropsOverlongLinesRatherThanTruncating() {
        // Half a sentence is not a spelling anybody wants enforced.
        let essay = String(repeating: "词", count: AppSettings.vocabularyTermLengthLimit + 1)
        #expect(AppSettings.parseVocabulary("Kevin\n\(essay)") == ["Kevin"])
        let atLimit = String(repeating: "词", count: AppSettings.vocabularyTermLengthLimit)
        #expect(AppSettings.parseVocabulary(atLimit) == [atLimit])
    }

    @Test func capsTheListLength() {
        // Every term rides along in every cleanup request.
        let many = (1...(AppSettings.vocabularyTermLimit + 20))
            .map { "term\($0)" }
            .joined(separator: "\n")
        #expect(AppSettings.parseVocabulary(many).count == AppSettings.vocabularyTermLimit)
    }

    @Test func nothingIsBiasedBehindTheBox() {
        // Keyword biasing fires on audio that merely sounds close, so every term has to
        // be one the user can delete. An emptied box means exactly that: bias nothing.
        #expect(AppSettings.parseVocabulary("") == [])
        #expect(AppSettings.parseVocabulary("Kevin\n李铭一\nAnthropic")
            == ["Kevin", "李铭一", "Anthropic"])
    }

    @Test func theSeedIsAnOfferOnceNotAStandingRule() {
        // A fresh install still gets the name typed for it.
        #expect(AppSettings.vocabularySeeded(into: "") == "李铭一")
        // An install that already lists it gains nothing — no second copy, and no
        // rewrite of a box that the parser would have edited on the way through.
        #expect(AppSettings.vocabularySeeded(into: "李铭一\nGavi") == nil)
        let essay = String(repeating: "词", count: AppSettings.vocabularyTermLengthLimit + 1)
        #expect(AppSettings.vocabularySeeded(into: "Gavi\n\(essay)") == "Gavi\n\(essay)\n李铭一")
    }

    @Test func termsThatWouldBeRejectedUpstreamNeverLeave() {
        // This list is now part of the Realtime session config, so an unacceptable term
        // does not cost one word — it fails `session.update` and takes dictation down
        // with it. Both rules are enforced again by the relay; this is the half that
        // keeps a legal-looking box from producing an illegal session.
        #expect(AppSettings.parseVocabulary("a<b") == [])
        #expect(AppSettings.parseVocabulary("a>b") == [])
        #expect(AppSettings.parseVocabulary("<transcript>") == [])

        // The cap is UTF-16 units, matching the relay's JavaScript check. 𠮷 is one
        // Character and two UTF-16 units, so 20 of them sit exactly on the limit and
        // 21 are over it — a distinction `count` alone cannot make.
        let atLimit = String(repeating: "𠮷", count: 20)
        let overLimit = String(repeating: "𠮷", count: 21)
        #expect(atLimit.count == 20 && atLimit.utf16.count == 40)
        #expect(AppSettings.parseVocabulary(atLimit) == [atLimit])
        #expect(AppSettings.parseVocabulary(overLimit) == [])
    }
}

// MARK: - Settings tables

@Suite struct TriggerKeyTests {
    @Test func deviceMasksAreDistinct() {
        let masks = TriggerKey.allCases.map(\.deviceMask)
        #expect(Set(masks).count == masks.count)
    }

    @Test func ownModifierIsNeverForeign() {
        // Holding the trigger key itself must not read as "user is typing a
        // shortcut" — that would cancel every dictation instantly.
        let command: UInt64 = 0x0010_0000
        let option: UInt64 = 0x0008_0000
        #expect(TriggerKey.rightCommand.foreignModifierMask & command == 0)
        #expect(TriggerKey.leftCommand.foreignModifierMask & command == 0)
        #expect(TriggerKey.rightOption.foreignModifierMask & option == 0)
        #expect(TriggerKey.leftOption.foreignModifierMask & option == 0)
    }

    @Test func onlySupportedTriggerKeysAreExposed() {
        #expect(TriggerKey.allCases.map(\.rawValue) == [
            "rightCommand", "leftCommand", "rightOption", "leftOption"
        ])
        #expect(TriggerKey(rawValue: "fn") == nil)
    }
}

@Suite struct SettingsTableTests {
    @Test func streamingModelsTypeLiveAndOnlyOpenAIExposesDelay() {
        // Both streaming models type as you speak; they differ in how. Gemini's
        // interim is a revisable snapshot, so the controller types only the prefix two
        // hypotheses agree on and takes revisions back with backspaces. Only OpenAI has
        // a latency knob to expose.
        #expect(TranscriptionModel.geminiLive.supportsLiveTyping)
        #expect(TranscriptionModel.liveTranscribe.supportsLiveTyping)
        #expect(!TranscriptionModel.transcribe.supportsLiveTyping)
        #expect(!TranscriptionModel.geminiLive.supportsTranscriptionDelay)
        #expect(TranscriptionModel.liveTranscribe.supportsTranscriptionDelay)
        #expect(TranscriptionModel.geminiLive.provider == .gemini)
        #expect(TranscriptionModel.liveTranscribe.provider == .openAI)
    }
}

// MARK: - First-run guide

@Suite struct OnboardingGateTests {
    /// The case the guide exists for: a DMG opened on a Mac that has never run it.
    @Test func aFreshInstallIsWalkedThroughSetup() {
        #expect(OnboardingGate.shouldPresent(
            completed: false, hasCredential: false, hasAccessibility: false
        ))
    }

    /// And the case that matters more, because it is the one nobody asked for: somebody
    /// who has been dictating for months updates into the build that added this window.
    /// Their completion flag was written by nobody, so the only evidence that they are
    /// set up is that they *are* set up — and a working install must never be stopped by
    /// a setup wizard.
    @Test func anAlreadyWorkingInstallIsNeverGreetedByTheGuide() {
        #expect(!OnboardingGate.shouldPresent(
            completed: false, hasCredential: true, hasAccessibility: true
        ))
    }

    /// Half-configured is not configured: a credential with no Accessibility permission
    /// cannot type a single character, and permission with no credential never connects.
    @Test func eitherHalfMissingStillOwesTheGuide() {
        #expect(OnboardingGate.shouldPresent(
            completed: false, hasCredential: true, hasAccessibility: false
        ))
        #expect(OnboardingGate.shouldPresent(
            completed: false, hasCredential: false, hasAccessibility: true
        ))
    }

    /// Revoked permissions remain a Settings problem, but removing direct mode creates
    /// a new hard credential prerequisite that an old completion flag cannot satisfy.
    @Test func aFinishedDirectInstallIsOfferedRelayCredentialRecovery() {
        #expect(OnboardingGate.shouldPresent(
            completed: true,
            owed: false,
            dismissed: false,
            hasCredential: false,
            hasAccessibility: false,
            hasMicrophone: false
        ))
        #expect(!OnboardingGate.shouldPresent(
            completed: true,
            owed: false,
            dismissed: false,
            hasCredential: true,
            hasAccessibility: false,
            hasMicrophone: false
        ))
        #expect(!OnboardingGate.shouldPresent(
            completed: true,
            owed: false,
            dismissed: true,
            hasCredential: false,
            hasAccessibility: true,
            hasMicrophone: true
        ))
    }

    /// 试一下 asks the user to dictate at the guide's own window, which is exactly the
    /// situation dictation otherwise refuses: no other app means nowhere to type. The
    /// rehearsal is that refusal turned into a demo — and it has to stay pinned to the
    /// guide, because "nowhere to type" also happens in ordinary use, when somebody
    /// switches away while the transcript is still coming back. That sentence goes to
    /// the clipboard; treating it as a rehearsal would silently destroy it.
    @Test func onlyTheGuideTurnsAMissingTargetIntoARehearsal() {
        #expect(DictationController.isRehearsal(hasTarget: false, isRehearsing: true))
        #expect(!DictationController.isRehearsal(hasTarget: false, isRehearsing: false))
        // And a real target is never a rehearsal, guide open or not: the user is typing
        // into a document and expects the words to arrive.
        #expect(!DictationController.isRehearsal(hasTarget: true, isRehearsing: true))
        #expect(!DictationController.isRehearsal(hasTarget: true, isRehearsing: false))
    }

    /// 完成 lives on the last step, so the flow has to end where the button does.
    @Test func theGuideStartsAtWelcomeAndEndsAtPractice() {
        #expect(OnboardingStep.allCases.first == .welcome)
        #expect(OnboardingStep.allCases.last == .practice)
        #expect(OnboardingStep.practice.next == nil)
        #expect(OnboardingStep.welcome.next == .connection)
    }
}

// MARK: - Keychain input validation

@Suite struct BundledTokenSeedingTests {
    /// Issuance numbers, standing in for `date +%s` at packaging time.
    private let older = 1_700_000_000
    private let newer = 1_800_000_000

    /// The sequence the packaging flow exists for, and the one the first version broke:
    /// seed a token, revoke it server-side, hand over a rebuilt copy. Deleting the app
    /// does not clear a keychain item, so if the new token cannot replace the old one
    /// the recipient is stuck on 401 with no way out from their side.
    @Test func aRebuiltCopyReplacesTheTokenItInstalledBefore() {
        // Nothing stored yet.
        #expect(KeychainStore.shouldSeed(
            hasStoredToken: false, bundledIssuance: older, adoptedIssuance: nil
        ))
        // Already applied this exact issuance — writing again would be pointless churn.
        #expect(!KeychainStore.shouldSeed(
            hasStoredToken: true, bundledIssuance: older, adoptedIssuance: older
        ))
        // A newer issuance replaces what this app installed before. The rotation case.
        #expect(KeychainStore.shouldSeed(
            hasStoredToken: true, bundledIssuance: newer, adoptedIssuance: older
        ))
    }

    /// A personalised build is handed to one person and its token is the hash the relay
    /// ledger records under their name. A stored token this app never applied an
    /// issuance for — hand-typed, enrolled by invite, or seeded before the scheme —
    /// loses to it, once. Refusing here is what makes revoking that person cut off a
    /// hash nobody is using.
    @Test func aPersonalisedBuildAdoptsItsOwnIdentityOverAnUnknownStoredToken() {
        #expect(KeychainStore.shouldSeed(
            hasStoredToken: true, bundledIssuance: older, adoptedIssuance: nil
        ))
    }

    /// …but exactly once. The issuance is recorded even though the user later replaces
    /// the token by hand, so the same build cannot reinstall itself on every launch and
    /// overwrite their choice forever.
    @Test func aTokenTheUserTypedAfterwardsSurvivesRelaunching() {
        #expect(!KeychainStore.shouldSeed(
            hasStoredToken: true, bundledIssuance: older, adoptedIssuance: older
        ))
    }

    /// Opening an older copy must not undo a newer one. This is the downgrade a
    /// value-comparison marker could not see: it proved only "this app wrote the current
    /// value", never which of two tokens came first, so the old copy read a working token
    /// as its own stale leftover and wrote a revoked one back over it.
    @Test func anOlderCopyNeverDowngradesANewerToken() {
        #expect(!KeychainStore.shouldSeed(
            hasStoredToken: true, bundledIssuance: older, adoptedIssuance: newer
        ))
        // And the 401 path cannot be used as a way around it — otherwise the downgrade
        // just happens one rejection later, to a token that is already revoked.
        #expect(!KeychainStore.mayRecoverWithBundled(
            bundledIssuance: older, adoptedIssuance: newer
        ))
    }

    /// A build with a token but no issuance stamp predates the ordering entirely, so it
    /// cannot be placed against anything: it may fill an empty slot and nothing more.
    @Test func anUnstampedBuildOnlyFillsAnEmptySlot() {
        #expect(KeychainStore.shouldSeed(
            hasStoredToken: false, bundledIssuance: nil, adoptedIssuance: nil
        ))
        #expect(!KeychainStore.shouldSeed(
            hasStoredToken: true, bundledIssuance: nil, adoptedIssuance: nil
        ))
        #expect(!KeychainStore.shouldSeed(
            hasStoredToken: true, bundledIssuance: nil, adoptedIssuance: older
        ))
    }

    /// Recovery from a rejected token is deliberately more permissive than seeding: a
    /// 401 is evidence the stored value does not work, which seeding never has.
    @Test func recoveryReinstallsThisBuildsTokenButNeverAnOlderOne() {
        // No history: the migration case, where there is nothing to contradict it.
        #expect(KeychainStore.mayRecoverWithBundled(bundledIssuance: older, adoptedIssuance: nil))
        // Its own issuance, re-applied — the stored value was hand-typed or rotated out.
        #expect(KeychainStore.mayRecoverWithBundled(bundledIssuance: older, adoptedIssuance: older))
        #expect(KeychainStore.mayRecoverWithBundled(bundledIssuance: newer, adoptedIssuance: older))
        // Unorderable against a real history — refuse rather than guess.
        #expect(!KeychainStore.mayRecoverWithBundled(bundledIssuance: nil, adoptedIssuance: older))
    }
}

@Suite struct KeychainInputTests {
    @Test func whitespaceOnlyRelayTokensAreRejectedWithoutTouchingTheKeychain() {
        #expect(!KeychainStore.saveRelayToken(""))
        #expect(!KeychainStore.saveRelayToken("   "))
        #expect(!KeychainStore.saveRelayToken(" \n\t"))
    }

    @Test func enrollmentTokenUsesURLSafeHighEntropyBytes() {
        let bytes = Data((0..<32).map(UInt8.init))
        let token = KeychainStore.relayToken(randomBytes: bytes)
        #expect(token == "relay_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        #expect(token?.contains("+") == false)
        #expect(token?.contains("/") == false)
        #expect(token.map(KeychainStore.isGeneratedRelayToken) == true)
        #expect(!KeychainStore.isGeneratedRelayToken("relay_short"))
        #expect(!KeychainStore.isGeneratedRelayToken("relay_\(String(repeating: "!", count: 43))"))
        #expect(KeychainStore.relayToken(randomBytes: Data(repeating: 0, count: 31)) == nil)
    }

    @Test func aRepeatedEnrollmentResponseRecognizesAnAlreadyPromotedToken() {
        let expected = "relay_\(String(repeating: "a", count: 43))"
        let other = "relay_\(String(repeating: "b", count: 43))"
        #expect(KeychainStore.relayEnrollmentCommitDecision(
            liveToken: expected,
            pendingToken: nil,
            expectedToken: expected
        ) == .alreadyCommitted)
        #expect(KeychainStore.relayEnrollmentCommitDecision(
            liveToken: expected,
            pendingToken: other,
            expectedToken: expected
        ) == .alreadyCommitted)
        #expect(KeychainStore.relayEnrollmentCommitDecision(
            liveToken: nil,
            pendingToken: expected,
            expectedToken: expected
        ) == .promotePending)
        #expect(KeychainStore.relayEnrollmentCommitDecision(
            liveToken: other,
            pendingToken: other,
            expectedToken: expected
        ) == .reject)
    }

    @Test func inviteValidationMatchesTheRelayFormat() {
        let code = "WHISPER-00112233-44556677-8899AABB-CCDDEEFF"
        #expect(RelayEnrollmentClient.isPlausibleInviteCode(code))
        #expect(RelayEnrollmentClient.isPlausibleInviteCode(code.lowercased()))
        #expect(!RelayEnrollmentClient.isPlausibleInviteCode("WHISPER-short"))
        #expect(!RelayEnrollmentClient.isPlausibleInviteCode(
            "WHISPER-00112233-44556677-8899AABB-CCDDEEFG"
        ))
        #expect(!RelayEnrollmentClient.isPlausibleInviteCode(
            "WHISPER-00112233-44556677-8899AABB-CCDDEEFＦ"
        ))
    }

    @Test func theInvitePromptIsExactlyAMissingDeviceToken() {
        // The relay is the only route, so activation has one question left: does this
        // Mac hold a device token? The old per-mode reasoning — an API key in the
        // Keychain, a connection mode the user had chosen — described a fork that no
        // longer exists.
        #expect(InviteEnrollmentOnboarding.shouldPresentInvite(
            inviteEnrollmentEnabled: true,
            hasRelayToken: false
        ))
        #expect(!InviteEnrollmentOnboarding.shouldPresentInvite(
            inviteEnrollmentEnabled: true,
            hasRelayToken: true
        ))
        #expect(!InviteEnrollmentOnboarding.shouldPresentInvite(
            inviteEnrollmentEnabled: false,
            hasRelayToken: false
        ))
    }
}

// MARK: - Relay routing

/// `.serialized` because `onlyALoopbackOverrideIsHonoured` writes the app's real
/// `UserDefaults` domain. Nothing else reads that key today, so this is locking in the
/// precondition rather than fixing an observed flake.
@Suite(.serialized) struct ServiceRouteTests {
    @Test func configuredRelayUsesHTTPS() {
        #expect(ServiceRoute.relayBaseURL.scheme == "https")
        #expect(ServiceRoute.relayBaseURL.host == "limingyi.com")
        #expect(ServiceRoute.relayBaseURL.path == "/whisper-relay")
    }

    @Test func loopbackHTTPIsAllowedForDevelopment() {
        #expect(ServiceRoute.relayBaseURL(from: "http://localhost:8787") != nil)
        #expect(ServiceRoute.relayBaseURL(from: "http://127.0.0.1:8787") != nil)
        #expect(ServiceRoute.relayBaseURL(from: "http://[::1]:8787") != nil)
    }

    @Test func credentialsQueryAndFragmentAreRejected() {
        #expect(ServiceRoute.relayBaseURL(from: "https://user@relay.example.com") == nil)
        #expect(ServiceRoute.relayBaseURL(from: "https://relay.example.com?token=secret") == nil)
        #expect(ServiceRoute.relayBaseURL(from: "https://relay.example.com/#secret") == nil)
    }

    @Test func relayPathsPreserveAnOptionalBasePath() throws {
        let base = try #require(
            ServiceRoute.relayBaseURL(from: "https://relay.example.com/whisper/")
        )
        #expect(base.appendingPathComponent("v1/polish").absoluteString
            == "https://relay.example.com/whisper/v1/polish")
        #expect(ServiceRoute.relayRealtimeURL(baseURL: base).absoluteString
            == "wss://relay.example.com/whisper/v1/realtime?intent=transcription&provider=openai")
        #expect(ServiceRoute.relayRealtimeURL(baseURL: base, provider: .gemini).absoluteString
            == "wss://relay.example.com/whisper/v1/realtime?intent=transcription&provider=gemini")
    }

    /// The deployed relay is published under a path prefix, so these are the exact
    /// strings the server has to answer on.
    @Test func productionRelayPathsMatchTheDeployedPrefix() {
        #expect(ServiceRoute.relayBaseURL.appendingPathComponent("v1/polish")
            .absoluteString == "https://limingyi.com/whisper-relay/v1/polish")
        #expect(ServiceRoute.relayRealtimeURL(baseURL: ServiceRoute.relayBaseURL)
            .absoluteString
            == "wss://limingyi.com/whisper-relay/v1/realtime?intent=transcription&provider=openai")
    }

    /// A stale or malformed development override must not be able to brick the app,
    /// and — the reason this is loopback-only — must never be usable to point a build
    /// holding a real device token at someone else's server. `UserDefaults` is writable
    /// by anything running as this user, so an override honouring arbitrary HTTPS hosts
    /// would make the app itself hand the Keychain token to an attacker on reconnect.
    @Test func onlyALoopbackOverrideIsHonoured() {
        let key = ServiceRoute.relayBaseURLOverrideKey
        let store = UserDefaults.standard
        let saved = store.string(forKey: key)
        defer {
            if let saved { store.set(saved, forKey: key) } else { store.removeObject(forKey: key) }
        }

        let rejected = [
            "", "not a url", "ftp://relay.example.com",
            "http://relay.example.com",
            // Valid, TLS, parses fine — and still refused, because it is not loopback.
            "https://attacker.example.com",
            "https://127.0.0.1.attacker.example.com",
        ]
        for bad in rejected {
            store.set(bad, forKey: key)
            #expect(
                ServiceRoute.effectiveRelayBaseURL == ServiceRoute.relayBaseURL,
                "override \"\(bad)\" must not be honoured"
            )
        }

        store.removeObject(forKey: key)
        #expect(ServiceRoute.effectiveRelayBaseURL == ServiceRoute.relayBaseURL)

        store.set("http://127.0.0.1:8787", forKey: key)
        #if DEBUG
        #expect(ServiceRoute.effectiveRelayBaseURL.absoluteString == "http://127.0.0.1:8787")
        #else
        #expect(ServiceRoute.effectiveRelayBaseURL == ServiceRoute.relayBaseURL)
        #endif
    }

    /// The struct holds a plaintext credential and now survives a whole utterance, so
    /// the one thing that must never happen is it being interpolated into a log line.
    @Test func interpolatingARouteNeverPrintsTheCredential() {
        let route = ServiceRoute(
            realtimeURL: URL(string: "wss://relay.example.com/v1/realtime")!,
            polishURL: URL(string: "https://relay.example.com/v1/polish")!,
            credential: "relay_super-secret-token"
        )
        let logged = "route=\(route)"
        #expect(!logged.contains("relay_super-secret-token"))
        // Still has to be worth logging: provider and host are the facts that matter.
        #expect(logged.contains("openai"))
        #expect(logged.contains("relay.example.com"))
    }

    /// `URLSessionWebSocketTask` collapses every rejected handshake into one opaque
    /// `NSURLErrorBadServerResponse` ("There was a bad response from the server"), so
    /// without reading the status off the task's `response` a revoked device token is
    /// indistinguishable from a dead café Wi-Fi — and the app burns all six backoff
    /// attempts on a credential that will never start working.
    @Test func aRejectedHandshakeSaysWhyItWasRefusedAndWhetherRetryingHelps() {
        let unauthorized = RealtimeClient.handshakeRejection(statusCode: 401)
        #expect(unauthorized.message.contains("设备凭证"))
        #expect(unauthorized.retryable == false)
        // The one failure a personalised build may repair by installing its bundled
        // token: our relay's auth answers a bad token with 401 and nothing else.
        #expect(unauthorized.rejectedCredential)

        // A 403 is Cloudflare or nginx, never the relay itself — it does not send 403.
        // Marking it a rejected credential once let one transient edge hiccup
        // *permanently* overwrite a hand-typed token with the bundled one.
        let edge = RealtimeClient.handshakeRejection(statusCode: 403)
        #expect(edge.rejectedCredential == false)
        #expect(edge.retryable)
        #expect(edge.message.contains("403"))
        #expect(!edge.message.contains("重新填写"))

        // Usually this device's own sleep/wake zombies still holding their slots. The
        // relay's heartbeat reaps them within a sweep or two, so this one must keep
        // retrying rather than stranding the user on a self-healing error.
        let throttled = RealtimeClient.handshakeRejection(statusCode: 429)
        #expect(throttled.message.contains("429"))
        #expect(throttled.retryable)

        // Anything unclassified still beats "There was a bad response from the server":
        // the status is the one fact that says whether it is the relay or the edge.
        let gateway = RealtimeClient.handshakeRejection(statusCode: 502)
        #expect(gateway.message.contains("502"))
        #expect(gateway.message.contains("转发服务器"))
        #expect(gateway.retryable)
    }
}

// MARK: - Audio constants

@Suite struct AudioFormatTests {
    @Test func bytesPerSecondMatches24kHzPCM16Mono() {
        // RealtimeClient's buffer capacity and upload-stall math all key off
        // this constant; the session is configured for audio/pcm at 24 kHz.
        #expect(AudioCapture.bytesPerSecond == 24_000 * 2)
    }
}

@Suite struct RealtimeClientAuditIdentityTests {
    @Test func knownHostsProduceControlledRelayAuditLabels() {
        #expect(
            RealtimeClient.clientAuditIdentity(
                bundleIdentifier: "com.mingyili.Whisper",
                version: "1.10"
            ) == .init(client: "whisper", version: "1.10")
        )
        #expect(
            RealtimeClient.clientAuditIdentity(
                bundleIdentifier: "com.wink.Wink",
                version: "0.1+5"
            ) == .init(client: "wink", version: "0.1+5")
        )
    }

    @Test func unknownOrUnsafeHostMetadataCannotReachRelayLogs() {
        #expect(
            RealtimeClient.clientAuditIdentity(
                bundleIdentifier: "com.example.Other",
                version: "1.0\nforged=true"
            ) == .init(client: "unknown", version: "unknown")
        )
        #expect(
            RealtimeClient.clientAuditIdentity(
                bundleIdentifier: nil,
                version: String(repeating: "1", count: 33)
            ) == .init(client: "unknown", version: "unknown")
        )
    }
}

@MainActor
@Suite struct RevisableInterimTypingTests {
    @Test func onlyThePrefixTwoHypothesesAgreeOnIsTyped() {
        // The volatile tail is held back, so a revision that changes it costs nothing.
        #expect(DictationController.stablePartialPrefix("好，现在测", "好，现在测试") == "好，现在测")
        #expect(DictationController.stablePartialPrefix("好，现在测", "好，现在吃") == "好，现在")
        #expect(DictationController.stablePartialPrefix("", "好").isEmpty)
    }

    @Test func interimSpacingAndPunctuationAreTightenedBetweenChineseCharacters() {
        #expect(
            DictationController.normalizeCJKTypography("好 , 现在 测试 一下 效果 .")
                == "好，现在测试一下效果。"
        )
        #expect(DictationController.normalizeCJKTypography("这样 吗 ?") == "这样吗？")
    }

    @Test func latinTextKeepsItsOwnSpacingAndPunctuation() {
        #expect(DictationController.normalizeCJKTypography("用 GPT 测试 一下") == "用 GPT 测试一下")
        #expect(DictationController.normalizeCJKTypography("version 1.10, ok") == "version 1.10, ok")
        #expect(DictationController.normalizeCJKTypography("hello world.") == "hello world.")
    }

    @Test func aTrailingSpaceIsNeverTypedOnlyToBeDeletedAgain() {
        #expect(DictationController.trimmingTrailingSpaces("好，现在 ") == "好，现在")
        #expect(DictationController.trimmingTrailingSpaces("hello") == "hello")
    }

    @Test func autocorrectOrPartialWritesCannotAuthorizeInterimBackspace() {
        // `false` covers both transformations of our typed text (such as autocorrect)
        // and a synthetic write that only partly reached the target.
        #expect(!DictationController.interimRevisionMayDelete(
            firstOwnershipProof: false,
            recheckedOwnershipProof: false
        ))
        #expect(!DictationController.interimRevisionMayDelete(
            firstOwnershipProof: true,
            recheckedOwnershipProof: false
        ))
    }

    @Test func unknownAXTextEvidenceFailsClosedForInterimBackspace() {
        #expect(!DictationController.interimRevisionMayDelete(
            firstOwnershipProof: false,
            recheckedOwnershipProof: false
        ))
        #expect(!DictationController.interimRevisionMayDelete(
            firstOwnershipProof: true,
            recheckedOwnershipProof: false
        ))
        #expect(DictationController.interimRevisionMayDelete(
            firstOwnershipProof: true,
            recheckedOwnershipProof: true
        ))
    }

    @Test func repeatedSuffixCannotStandInForTheOriginalInsertionPosition() {
        let original = CFRange(location: 10, length: 0)
        #expect(TextInjector.selectionMatches(
            snapshot: original,
            current: CFRange(location: 11, length: 0),
            insertedUTF16Count: 1
        ))
        // Whisper inserted one "a", then the user inserted the same suffix. Text alone
        // still matches, but the caret is one position beyond Whisper's owned range.
        #expect(!TextInjector.selectionMatches(
            snapshot: original,
            current: CFRange(location: 12, length: 0),
            insertedUTF16Count: 1
        ))
    }

    @Test func liveTypingRequiresPositiveExactFieldEvidence() {
        #expect(DictationController.canContinueLiveInjection(
            anchorUnchanged: true,
            exactElementFocused: true
        ))
        #expect(!DictationController.canContinueLiveInjection(
            anchorUnchanged: true,
            exactElementFocused: nil
        ))
        #expect(!DictationController.canContinueLiveInjection(
            anchorUnchanged: true,
            exactElementFocused: false
        ))
        #expect(DictationController.liveInjectionFieldDisposition(
            anchorUnchanged: true,
            exactElementFocused: nil
        ) == .deferToFinalPaste)
        #expect(DictationController.liveInjectionFieldDisposition(
            anchorUnchanged: true,
            exactElementFocused: false
        ) == .abandonTarget)
        #expect(DictationController.liveInjectionFieldDisposition(
            anchorUnchanged: false,
            exactElementFocused: nil
        ) == .abandonTarget)
    }

    @Test func finalSuffixTypingRequiresPositiveOriginalFieldOwnership() {
        #expect(DictationController.finalAdditionMayType(
            originalFieldOwnershipProof: true
        ))
        #expect(!DictationController.finalAdditionMayType(
            originalFieldOwnershipProof: false
        ))
        #expect(!DictationController.finalAdditionMayType(
            originalFieldOwnershipProof: nil
        ))
    }

    @Test func finalBackspaceRequiresTwoPositiveDocumentProofs() {
        #expect(!DictationController.rewriteMayDelete(
            typedTextStillBeforeCaret: nil,
            sameElementStillFocused: nil
        ))
        #expect(!DictationController.rewriteMayStillDelete(
            firstTextProof: true,
            recheckedTextProof: nil,
            sameElementStillFocused: true
        ))
        #expect(DictationController.rewriteMayStillDelete(
            firstTextProof: true,
            recheckedTextProof: true,
            sameElementStillFocused: true
        ))
    }
}

@Suite struct OnboardingCredentialPolicyTests {
    @Test func legacyDirectRecoveryOverridesDismissalExactlyOnce() {
        #expect(LegacyCredentialRecoveryPolicy.shouldSchedule(
            hadLegacyCredential: true,
            hasRelayToken: false,
            wasAlreadyScheduled: false
        ))
        #expect(!LegacyCredentialRecoveryPolicy.shouldSchedule(
            hadLegacyCredential: true,
            hasRelayToken: false,
            wasAlreadyScheduled: true
        ))
        #expect(!LegacyCredentialRecoveryPolicy.shouldSchedule(
            hadLegacyCredential: true,
            hasRelayToken: true,
            wasAlreadyScheduled: false
        ))
        #expect(OnboardingGate.shouldPresent(
            completed: false,
            owed: false,
            dismissed: true,
            requiresCredentialRecovery: true,
            hasCredential: false,
            hasAccessibility: true,
            hasMicrophone: true
        ))
    }

    @Test func suppressedPresentationDoesNotEraseDismissal() {
        #expect(!OnboardingPresentationPolicy.shouldMarkImplicitCompletion(
            dismissed: true
        ))
        #expect(OnboardingPresentationPolicy.shouldMarkImplicitCompletion(
            dismissed: false
        ))
    }

    @Test func editorMatchesTheBuildEnrollmentCapability() {
        #expect(OnboardingCredentialPolicy.editor(inviteEnrollmentEnabled: true) == .invite)
        #expect(
            OnboardingCredentialPolicy.editor(inviteEnrollmentEnabled: false)
                == .manualRelayToken
        )
    }

    @Test func manualDeviceTokenIsValidatedAndTrimmed() {
        let token = "relay_" + String(repeating: "a", count: 43)
        #expect(OnboardingCredentialPolicy.manualRelayToken(from: "  \(token)  ") == token)
        #expect(OnboardingCredentialPolicy.manualRelayToken(from: "relay_device") == nil)
        #expect(OnboardingCredentialPolicy.manualRelayToken(from: "x") == nil)
        #expect(OnboardingCredentialPolicy.manualRelayToken(from: " \n\t ") == nil)
    }
}
