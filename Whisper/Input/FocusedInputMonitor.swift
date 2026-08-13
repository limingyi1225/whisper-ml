import AppKit
import ApplicationServices

private struct FocusedInputProbeRequest: Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
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
            let isEditable = Self.probeFocusedInput(
                processIdentifier: request.processIdentifier,
                bundleIdentifier: request.bundleIdentifier
            )
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.probeIsInFlight = false

                    if self.probeEpoch == request.epoch,
                       self.observedProcessIdentifier == request.processIdentifier,
                       self.eligibleFrontmostProcessIdentifier() == request.processIdentifier,
                       !Permissions.isSecureInputEnabled {
                        self.publish(isEditable)
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
        bundleIdentifier: String?
    ) -> Bool {
        let application = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, 0.15)
        if usesAppWideInputFallback(bundleIdentifier: bundleIdentifier) {
            // These frontmost apps expose their editors inconsistently or not at all.
            // The explicit product policy is to prefer a harmless extra idle HUD over
            // missing the affordance while the user is preparing to type.
            return true
        }

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedElement = checkedAXElement(from: focusedValue) else {
            return false
        }

        _ = AXUIElementSetMessagingTimeout(focusedElement, 0.15)
        if isEditableTextElement(focusedElement) {
            return true
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
                return true
            }
        }
        return containsEditableTextDescendant(of: focusedElement)
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
