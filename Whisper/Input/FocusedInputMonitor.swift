import AppKit
import ApplicationServices

/// A focused input, no focused input, and an app that has not published a focused
/// element at all are three different answers. Chromium builds the tree for page
/// content only once a client declares itself, and until then it gives the third —
/// which is why a text box on a web page and a video playing full screen used to look
/// identical from out here.
private enum FocusedInputVerdict: Sendable {
    case editable
    case notEditable
    case noFocusPublished
}

private struct FocusedInputProbeRequest: Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let overlayProcessIdentifiers: [pid_t]
    let epoch: Int
}

/// Tracks whether keyboard focus is currently inside an editable text control in the
/// frontmost application. AX notifications cover ordinary and programmatic focus moves;
/// mouse clicks and keyboard transitions provide a cheap fallback for apps whose AX
/// notification implementation is incomplete.
@MainActor
final class FocusedInputMonitor {
    var onChange: ((Bool) -> Void)?
    private(set) var hasFocusedEditableInput = false

    private var activationObserver: NSObjectProtocol?
    private var accessibilityObserver: AXObserver?
    private var observedApplication: AXUIElement?
    private var observedProcessIdentifier: pid_t?
    private var receivesFocusNotifications = false
    private var mouseMonitor: Any?
    private var keyboardMonitor: Any?
    private var healthTimer: Timer?
    private var healthTick = 0
    private var refreshEpoch = 0
    private var probeEpoch = 0
    private var pendingProbe: FocusedInputProbeRequest?
    private var probeIsInFlight = false
    private var cachedOverlayProcessIdentifiers: [pid_t] = []
    private var overlayLookupAt: Date?
    private var lastAccessibilityRequestAt: Date?
    private let probeQueue = DispatchQueue(
        label: "com.mingyili.Whisper.focused-input-probe",
        qos: .userInteractive
    )

    func start() {
        guard activationObserver == nil else { return }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.bindToFrontmostApplication()
            }
        }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                // Office can move focus to a layout container first and expose its
                // nested editor only after the click sequence has settled.
                MainActor.assumeIsolated { self?.scheduleRefreshes(after: [0.05, 0.3]) }
            }
        }

        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self,
                          Self.shouldRefreshAfterKeyDown(
                            keyCode: event.keyCode,
                            hasFocusedEditableInput: self.hasFocusedEditableInput
                          ) else {
                        return
                    }
                    self.scheduleRefreshes(after: [0.05, 0.3])
                }
            }
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHealth() }
        }
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        bindToFrontmostApplication()
    }

    func stop() {
        refreshEpoch += 1
        probeEpoch += 1
        pendingProbe = nil
        healthTimer?.invalidate()
        healthTimer = nil

        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }

        detachAccessibilityObserver()
        publish(false)
    }

    private func refreshHealth() {
        guard Permissions.hasAccessibility else {
            if accessibilityObserver != nil {
                detachAccessibilityObserver()
            } else {
                probeEpoch += 1
                pendingProbe = nil
            }
            publish(false)
            return
        }
        guard !Permissions.isSecureInputEnabled else {
            probeEpoch += 1
            pendingProbe = nil
            publish(false)
            return
        }

        let frontmostPID = eligibleFrontmostProcessIdentifier()
        if frontmostPID != observedProcessIdentifier || accessibilityObserver == nil {
            bindToFrontmostApplication()
        } else {
            healthTick &+= 1
            // Registration success only proves that an app accepted the observer;
            // Web/Electron/Office editors do not always emit every focus transition.
            if Self.shouldRunHealthProbe(
                receivesFocusNotifications: receivesFocusNotifications,
                healthTick: healthTick
            ) {
                refreshFocusedInput()
            }
        }
    }

    nonisolated static func shouldRunHealthProbe(
        receivesFocusNotifications: Bool,
        healthTick: Int
    ) -> Bool {
        if !receivesFocusNotifications {
            return true
        }
        return healthTick.isMultiple(of: 2)
    }

    private func beginNextProbeIfNeeded() {
        guard !probeIsInFlight, let request = pendingProbe else { return }
        pendingProbe = nil
        probeIsInFlight = true

        probeQueue.async { [weak self] in
            let verdict = Self.probeFocusedInput(
                processIdentifier: request.processIdentifier,
                bundleIdentifier: request.bundleIdentifier,
                overlayProcessIdentifiers: request.overlayProcessIdentifiers
            )
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.probeIsInFlight = false

                    if self.probeEpoch == request.epoch,
                       self.observedProcessIdentifier == request.processIdentifier,
                       self.eligibleFrontmostProcessIdentifier() == request.processIdentifier,
                       !Permissions.isSecureInputEnabled {
                        self.publish(verdict == .editable)
                        if case .noFocusPublished = verdict {
                            self.requestAccessibilityTree(
                                from: request.processIdentifier
                            )
                        }
                    }
                    // Requests arriving while AX was busy overwrite one pending slot;
                    // stale work never forms an unbounded serial queue.
                    self.beginNextProbeIfNeeded()
                }
            }
        }
    }

    private func refreshFocusedInput() {
        guard Permissions.hasAccessibility,
              !Permissions.isSecureInputEnabled,
              observedApplication != nil,
              let observedProcessIdentifier,
              let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier == observedProcessIdentifier else {
            probeEpoch += 1
            pendingProbe = nil
            publish(false)
            return
        }

        probeEpoch += 1
        pendingProbe = FocusedInputProbeRequest(
            processIdentifier: observedProcessIdentifier,
            bundleIdentifier: frontmostApplication.bundleIdentifier,
            overlayProcessIdentifiers: overlayInputProcessIdentifiers(),
            epoch: probeEpoch
        )
        beginNextProbeIfNeeded()
    }

    private func bindToFrontmostApplication() {
        detachAccessibilityObserver()
        healthTick = 0

        guard Permissions.hasAccessibility,
              let processIdentifier = eligibleFrontmostProcessIdentifier() else {
            publish(false)
            return
        }

        let application = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, 0.15)

        var observer: AXObserver?
        guard AXObserverCreate(
            processIdentifier,
            focusedInputObserverCallback,
            &observer
        ) == .success, let observer else {
            publish(false)
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let focusResult = AXObserverAddNotification(
            observer,
            application,
            kAXFocusedUIElementChangedNotification as CFString,
            context
        )
        _ = AXObserverAddNotification(
            observer,
            application,
            kAXFocusedWindowChangedNotification as CFString,
            context
        )
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )

        accessibilityObserver = observer
        observedApplication = application
        observedProcessIdentifier = processIdentifier
        receivesFocusNotifications = focusResult == .success
        refreshFocusedInput()
    }

    private func detachAccessibilityObserver() {
        probeEpoch += 1
        pendingProbe = nil
        if let accessibilityObserver, let observedApplication {
            _ = AXObserverRemoveNotification(
                accessibilityObserver,
                observedApplication,
                kAXFocusedUIElementChangedNotification as CFString
            )
            _ = AXObserverRemoveNotification(
                accessibilityObserver,
                observedApplication,
                kAXFocusedWindowChangedNotification as CFString
            )
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(accessibilityObserver),
                .commonModes
            )
        }
        accessibilityObserver = nil
        observedApplication = nil
        observedProcessIdentifier = nil
        receivesFocusNotifications = false
    }

    /// Asks an app to publish its accessibility tree.
    ///
    /// Chrome answers `AXFocusedUIElement` with nothing at all until a client
    /// identifies itself as assistive software — not "the focused thing is not
    /// editable" but "there is no focused thing" — so every text box on every web page
    /// gave the same answer as a video playing full screen, and the pill stayed dark
    /// for both. Setting this is what turns the page tree on; the tree appears about
    /// two seconds later and ordinary probing picks it up from there. Chrome reports
    /// the attribute as unsupported while acting on it anyway, so the result is worth
    /// nothing and is not read.
    ///
    /// Asked again while the app keeps coming back empty, rather than once per
    /// process. A browser that has only just launched is not yet listening: measured
    /// against Chrome, the first ask went out 0.4 s after the process appeared and was
    /// dropped on the floor, so latching "already asked" left the pill dark for that
    /// entire run of the browser. Repeating stops on its own the moment the tree
    /// exists, because the app then answers the focus question and never reaches here.
    ///
    /// Unlike every other Accessibility call in this file, this one runs on the main
    /// thread, and has to. Sent from the probe queue it is simply ignored — Chrome
    /// went on publishing nothing through fourteen consecutive asks, and woke on the
    /// first identical call made from the main thread. It is affordable there because
    /// it does not wait for an answer: the call returns immediately, the messaging
    /// timeout caps a hung app at 0.15 s, and the interval keeps even that worst case
    /// rare.
    ///
    /// Deliberately not a list of browsers. The declaration is simply true — Whisper
    /// is an Accessibility client, and holds the permission to prove it — and an app
    /// that builds its tree eagerly never reaches this path, because it answered the
    /// focus question in the first place.
    private func requestAccessibilityTree(from processIdentifier: pid_t) {
        let now = Date()
        guard Self.shouldSendAccessibilityRequest(
            lastSentAt: lastAccessibilityRequestAt,
            now: now
        ) else {
            return
        }
        lastAccessibilityRequestAt = now

        let application = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, 0.15)
        _ = AXUIElementSetAttributeValue(
            application,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
    }

    /// Deliberately not keyed on the process. Keeping a per-app timestamp meant that
    /// alternating between two apps that both publish nothing reset the interval on
    /// every switch, so the main-thread call this rate limit exists to bound went out
    /// on every ⌘-Tab. A single clock costs a cold app at most one extra interval.
    nonisolated static func shouldSendAccessibilityRequest(
        lastSentAt: Date?,
        now: Date
    ) -> Bool {
        guard let lastSentAt else { return true }
        return now.timeIntervalSince(lastSentAt) >= accessibilityRequestInterval
    }

    /// Chrome publishes its tree about two seconds after being asked, so asking more
    /// often than this only repeats work the browser is already doing.
    private static let accessibilityRequestInterval: TimeInterval = 2

    /// The processes that draw a text field over the top of whatever is in front,
    /// resolved on the main actor so the probe queue never touches `NSWorkspace`.
    ///
    /// An empty answer is cached like any other. Caching only non-empty results meant
    /// that a system where the list matches nothing — a macOS that has renamed the
    /// Spotlight host process again, as it already did once — enumerated every running
    /// application on the main thread once a second, forever, with no symptom beyond
    /// a Spotlight pill that quietly never appeared.
    private func overlayInputProcessIdentifiers() -> [pid_t] {
        // Liveness alone is not enough: a pid outlives nothing, and the kernel hands
        // it on. An entry whose process has been replaced by an unrelated app would
        // otherwise survive the whole interval, and its focused element would be read
        // as a Spotlight panel — lighting the pill from an app that is not even in
        // front. Asking for the bundle identifier costs the same lookup.
        let hasStaleEntry = cachedOverlayProcessIdentifiers.contains {
            !Self.isOverlayInputSurface(
                bundleIdentifier: NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
            )
        }
        if !hasStaleEntry,
           let resolvedAt = overlayLookupAt,
           Date().timeIntervalSince(resolvedAt) < Self.overlayLookupInterval {
            return cachedOverlayProcessIdentifiers
        }

        overlayLookupAt = Date()
        cachedOverlayProcessIdentifiers = NSWorkspace.shared.runningApplications
            .filter { Self.isOverlayInputSurface(bundleIdentifier: $0.bundleIdentifier) }
            .map(\.processIdentifier)
        return cachedOverlayProcessIdentifiers
    }

    /// Long enough that the scan is not a per-probe cost, short enough that Spotlight
    /// works again within half a minute of its process being replaced.
    private static let overlayLookupInterval: TimeInterval = 30

    private func eligibleFrontmostProcessIdentifier() -> pid_t? {
        guard let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return processIdentifier
    }

    private func scheduleRefreshes(after delays: [TimeInterval] = [0.05]) {
        refreshEpoch += 1
        let epoch = refreshEpoch
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.refreshEpoch == epoch else { return }
                    self.refreshFocusedInput()
                }
            }
        }
    }

    fileprivate func accessibilityFocusChanged() {
        scheduleRefreshes()
    }

    private func publish(_ newValue: Bool) {
        guard hasFocusedEditableInput != newValue else { return }
        hasFocusedEditableInput = newValue
        onChange?(newValue)
    }

    /// AX requests are deliberately executed off the main thread. A responsive app
    /// answers immediately; a hung app can consume the per-element timeout several
    /// times, and must not stall the hotkey's main-run-loop event tap while doing so.
    private nonisolated static func probeFocusedInput(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        overlayProcessIdentifiers: [pid_t]
    ) -> FocusedInputVerdict {
        let verdict = probeFrontmostInput(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        if case .editable = verdict {
            return .editable
        }
        if probeOverlayInput(overlayProcessIdentifiers) {
            return .editable
        }
        return verdict
    }

    /// One AX round-trip per overlay process, taken only once the frontmost app has
    /// already answered no. A process with no panel up reports no focused element at
    /// all, so this cannot light the pill while Spotlight is closed.
    private nonisolated static func probeOverlayInput(
        _ processIdentifiers: [pid_t]
    ) -> Bool {
        for processIdentifier in processIdentifiers {
            let application = AXUIElementCreateApplication(processIdentifier)
            _ = AXUIElementSetMessagingTimeout(application, 0.15)
            guard case .element(let focusedElement) =
                    copyFocusedElement(of: application) else {
                continue
            }
            if isEditableTextElement(focusedElement) {
                return true
            }
        }
        return false
    }

    private nonisolated static func probeFrontmostInput(
        processIdentifier: pid_t,
        bundleIdentifier: String?
    ) -> FocusedInputVerdict {
        let application = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, 0.15)
        if usesAppWideInputFallback(bundleIdentifier: bundleIdentifier) {
            // These frontmost apps expose their editors inconsistently or not at all.
            // The explicit product policy is to prefer a harmless extra idle HUD over
            // missing the affordance while the user is preparing to type.
            return .editable
        }

        let focusedElement: AXUIElement
        switch copyFocusedElement(of: application) {
        case .element(let element):
            focusedElement = element
        case .nothingFocused:
            return .noFocusPublished
        case .unavailable:
            return .notEditable
        }

        _ = AXUIElementSetMessagingTimeout(focusedElement, 0.15)
        if isEditableTextElement(focusedElement) {
            return .editable
        }
        for attribute in ["AXEditableAncestor", "AXHighestEditableAncestor"] {
            var ancestorValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                focusedElement,
                attribute as CFString,
                &ancestorValue
            ) == .success,
               let ancestorElement = checkedAXElement(from: ancestorValue),
               isEditableTextElement(ancestorElement) {
                return .editable
            }
        }
        return containsEditableTextDescendant(of: focusedElement) ? .editable : .notEditable
    }

    /// Reading a focused element has three outcomes, and the difference between the
    /// last two decides whether an app gets told an assistive client is attached.
    private enum FocusedElementLookup {
        case element(AXUIElement)
        /// The app replied, and the reply was that nothing is focused. This is what
        /// a lazily-built tree says before anything has asked it to exist.
        case nothingFocused
        /// The app did not reply at all — busy, hung, or gone. It has made no
        /// statement about its tree, and must not be treated as if it had.
        case unavailable
    }

    private nonisolated static func copyFocusedElement(
        of application: AXUIElement
    ) -> FocusedElementLookup {
        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        if result == .success, let element = checkedAXElement(from: focusedValue) {
            return .element(element)
        }
        return publishesNoFocus(axError: result) ? .nothingFocused : .unavailable
    }

    /// Which reply counts as "there is nothing focused" rather than "no reply".
    ///
    /// Exactly one, and it is the one Chrome was measured to give. `.cannotComplete`
    /// is the timeout a hung app produces — the very error this file elsewhere uses to
    /// recognise one — so a merely slow app must not be read as an app whose tree does
    /// not exist. `.attributeUnsupported` is excluded for the opposite reason: an app
    /// that does not implement the attribute at all has no lazily-built tree to wake,
    /// so declaring to it every two seconds could only ever be noise.
    nonisolated static func publishesNoFocus(axError: AXError) -> Bool {
        axError == .noValue
    }

    private nonisolated static func isEditableTextElement(_ element: AXUIElement) -> Bool {
        _ = AXUIElementSetMessagingTimeout(element, 0.05)
        let role = stringAttribute(kAXRoleAttribute as CFString, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: element)
        let enabled = boolAttribute(kAXEnabledAttribute as CFString, from: element) ?? true
        let hidden = boolAttribute("AXHidden" as CFString, from: element) ?? false
        guard !hidden else { return false }

        let valueIsSettable: Bool
        let selectionIsSettable: Bool
        if role == kAXTextFieldRole as String || role == kAXTextAreaRole as String {
            valueIsSettable = isAttributeSettable(kAXValueAttribute as CFString, on: element)
            selectionIsSettable = isAttributeSettable(
                kAXSelectedTextRangeAttribute as CFString,
                on: element
            )
        } else if role == kAXComboBoxRole as String
                    || role == "AXWebArea"
                    || role == "AXDocument" {
            valueIsSettable = isAttributeSettable(kAXValueAttribute as CFString, on: element)
            selectionIsSettable = false
        } else {
            valueIsSettable = false
            selectionIsSettable = false
        }

        return isEditableText(
            role: role,
            subrole: subrole,
            enabled: enabled,
            valueIsSettable: valueIsSettable,
            selectionIsSettable: selectionIsSettable
        )
    }

    nonisolated static func isEditableText(
        role: String?,
        subrole: String?,
        enabled: Bool,
        valueIsSettable: Bool,
        selectionIsSettable: Bool
    ) -> Bool {
        guard subrole != kAXSecureTextFieldSubrole as String else { return false }
        // Word can report AXEnabled=false for its live page editor even though the
        // text attributes are writable. Settable capability is stronger evidence.
        guard enabled || valueIsSettable || selectionIsSettable else { return false }

        if role == kAXTextFieldRole as String || role == kAXTextAreaRole as String {
            return valueIsSettable || selectionIsSettable
        }
        if role == kAXComboBoxRole as String {
            return valueIsSettable
        }
        if role == "AXWebArea" || role == "AXDocument" {
            return valueIsSettable
        }
        return false
    }

    nonisolated static func shouldSearchEditableDescendants(of role: String?) -> Bool {
        role == kAXGroupRole as String
            || role == kAXSplitGroupRole as String
            || role == kAXScrollAreaRole as String
            || role == kAXLayoutAreaRole as String
            || role == "AXLayoutItem"
    }

    nonisolated static func shouldRefreshAfterKeyDown(
        keyCode: UInt16,
        hasFocusedEditableInput: Bool
    ) -> Bool {
        // The first keystroke can itself enter an Office shape's text editor. Once
        // already editing, ordinary typing cannot move focus; only navigation/edit
        // mode keys need another AX query.
        !hasFocusedEditableInput || [36, 48, 53, 76, 120].contains(keyCode)
    }

    nonisolated static func usesAppWideInputFallback(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.tencent.xinWeChat"
            || bundleIdentifier == "com.microsoft.Powerpoint"
            || bundleIdentifier == "com.anthropic.claudefordesktop"
            || bundleIdentifier == "com.openai.codex"
            || bundleIdentifier == "com.apple.Safari"
    }

    /// Spotlight never becomes the frontmost application. Its panel is drawn by a
    /// background process — `com.apple.campo` from macOS 26 on, `com.apple.Spotlight`
    /// before that — while `NSWorkspace.frontmostApplication` goes on naming whatever
    /// was already there. Probing the frontmost app alone therefore answers a question
    /// about the wrong window: the resting pill appeared or not according to what
    /// happened to be sitting behind Spotlight, even though the caret was in a search
    /// field the whole time.
    nonisolated static func isOverlayInputSurface(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.apple.campo"
            || bundleIdentifier == "com.apple.Spotlight"
    }

    nonisolated static func checkedAXElement(from value: CFTypeRef?) -> AXUIElement? {
        guard let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        // Core Foundation references do not support a meaningful conditional cast:
        // Swift reports `as? AXUIElement` as always succeeding. The Type ID check is
        // therefore the safety boundary before reinterpreting the retained CF object.
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    nonisolated static func boundedChildReadCount(
        reportedChildCount: Int,
        queuedElementCount: Int,
        maximumElements: Int,
        pageSize: Int
    ) -> Int {
        let remainingCapacity = max(0, maximumElements - queuedElementCount)
        return max(0, min(reportedChildCount, remainingCapacity, pageSize))
    }

    private nonisolated static func containsEditableTextDescendant(
        of root: AXUIElement
    ) -> Bool {
        _ = AXUIElementSetMessagingTimeout(root, 0.05)
        let rootRole = stringAttribute(kAXRoleAttribute as CFString, from: root)
        guard shouldSearchEditableDescendants(of: rootRole) else { return false }

        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var visited = Set<ObjectIdentifier>()
        var index = 0
        let maximumElements = 256
        let maximumDepth = 10
        let childPageSize = 64
        let deadline = CFAbsoluteTimeGetCurrent() + 0.3

        while index < queue.count,
              index < maximumElements,
              CFAbsoluteTimeGetCurrent() < deadline {
            let current = queue[index]
            index += 1
            _ = AXUIElementSetMessagingTimeout(current.element, 0.05)
            let identity = ObjectIdentifier(current.element)
            guard visited.insert(identity).inserted else { continue }

            if current.depth > 0, isEditableTextElement(current.element) {
                return true
            }
            guard current.depth < maximumDepth else { continue }
            let role = stringAttribute(kAXRoleAttribute as CFString, from: current.element)
            guard shouldSearchEditableDescendants(of: role) else { continue }

            var childCount: CFIndex = 0
            guard CFAbsoluteTimeGetCurrent() < deadline,
                  AXUIElementGetAttributeValueCount(
                current.element,
                kAXChildrenAttribute as CFString,
                &childCount
            ) == .success,
                  childCount > 0 else {
                continue
            }

            var childIndex: CFIndex = 0
            while childIndex < childCount,
                  queue.count < maximumElements,
                  CFAbsoluteTimeGetCurrent() < deadline {
                let requestedCount = boundedChildReadCount(
                    reportedChildCount: childCount - childIndex,
                    queuedElementCount: queue.count,
                    maximumElements: maximumElements,
                    pageSize: childPageSize
                )
                guard requestedCount > 0 else { break }

                var childPage: CFArray?
                let copyResult = AXUIElementCopyAttributeValues(
                    current.element,
                    kAXChildrenAttribute as CFString,
                    childIndex,
                    requestedCount,
                    &childPage
                )
                childIndex += requestedCount
                guard copyResult == .success, let childPage else { break }

                for childValue in childPage as [AnyObject] {
                    guard queue.count < maximumElements,
                          CFAbsoluteTimeGetCurrent() < deadline else {
                        break
                    }
                    guard let child = checkedAXElement(from: childValue) else { continue }
                    queue.append((child, current.depth + 1))
                }
            }
        }
        return false
    }

    private nonisolated static func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private nonisolated static func boolAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private nonisolated static func isAttributeSettable(
        _ attribute: CFString,
        on element: AXUIElement
    ) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
            && settable.boolValue
    }
}

private nonisolated func focusedInputObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let monitor = Unmanaged<FocusedInputMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.accessibilityFocusChanged()
    }
}
