import Testing
@testable import Whisper

@Suite struct OnboardingRegressionTests {
    @Test func postponingActivationDismissesAndLeavesSetupOwed() {
        #expect(OnboardingStep.connection.skipAction == .dismissOwed)
        #expect(OnboardingStep.welcome.skipAction == nil)
        #expect(OnboardingStep.permissions.skipAction == nil)
        #expect(OnboardingStep.practice.skipAction == nil)
        #expect(!OnboardingCompletionPolicy.shouldMarkCompleted(
            reason: .postponed,
            preview: false
        ))
        #expect(OnboardingGate.shouldPresent(
            completed: false,
            owed: true,
            hasCredential: true,
            hasAccessibility: true
        ))
    }

    @Test func onlyAnActuallyStartedWalkthroughOverridesLegacyUpgradeInference() {
        // A working installation from before onboarding existed has no marker and must
        // not be interrupted merely because the new completion key is absent.
        #expect(!OnboardingGate.shouldPresent(
            completed: false,
            owed: false,
            hasCredential: true,
            hasAccessibility: true
        ))
        // Once the window has really been shown, machine state is no longer a proxy for
        // completion: closing after saving a credential/granting AX still owes the flow,
        // because the microphone may still be missing.
        #expect(OnboardingGate.shouldPresent(
            completed: false,
            owed: true,
            dismissed: false,
            hasCredential: true,
            hasAccessibility: true,
            hasMicrophone: false
        ))
    }

    /// The trap this gate had: `present()` writes the owed marker before the window is
    /// drawn, and only the 完成 button cleared it. Walking the whole guide and then
    /// closing with the red dot re-opened it, stealing focus, on every launch forever.
    @Test func finishedSetupIsFinishedWhicheverWayTheWindowWasClosed() {
        #expect(!OnboardingGate.shouldPresent(
            completed: false,
            owed: true,
            dismissed: false,
            hasCredential: true,
            hasAccessibility: true,
            hasMicrophone: true
        ))
    }

    /// The other half: a step somebody genuinely cannot pass — a managed Mac where
    /// Accessibility is denied by profile — must not hold every launch hostage. Closing
    /// the window stops the automatic presentation; the menu item is the way back.
    @Test func anExplicitDismissalStopsTheLaunchTimePresentation() {
        #expect(OnboardingGate.shouldPresent(
            completed: false,
            owed: true,
            dismissed: false,
            hasCredential: true,
            hasAccessibility: false,
            hasMicrophone: true
        ))
        #expect(!OnboardingGate.shouldPresent(
            completed: false,
            owed: true,
            dismissed: true,
            hasCredential: true,
            hasAccessibility: false,
            hasMicrophone: true
        ))
    }

    @Test func showAgainDoesNotTurnALegacyWorkingInstallIntoSetupDebt() {
        let legacyWorkingInstallNeedsSetup = OnboardingGate.shouldPresent(
            completed: false,
            owed: false,
            hasCredential: true,
            hasAccessibility: true
        )
        #expect(!OnboardingPresentationPolicy.shouldTrackCompletion(
            preview: false,
            normallyNeedsSetup: legacyWorkingInstallNeedsSetup
        ))

        let freshIncompleteInstallNeedsSetup = OnboardingGate.shouldPresent(
            completed: false,
            owed: false,
            hasCredential: false,
            hasAccessibility: false
        )
        #expect(OnboardingPresentationPolicy.shouldTrackCompletion(
            preview: false,
            normallyNeedsSetup: freshIncompleteInstallNeedsSetup
        ))
        #expect(!OnboardingPresentationPolicy.shouldTrackCompletion(
            preview: true,
            normallyNeedsSetup: freshIncompleteInstallNeedsSetup
        ))
    }

    @Test func anInProgressWalkthroughRequiresMicrophoneToo() {
        #expect(!OnboardingRequirements.areSatisfied(
            hasCredential: true,
            hasAccessibility: true,
            hasMicrophone: false
        ))
        #expect(OnboardingRequirements.areSatisfied(
            hasCredential: true,
            hasAccessibility: true,
            hasMicrophone: true
        ))
    }

    @Test func onlyARealCompletedWalkthroughWritesCompletion() {
        #expect(OnboardingCompletionPolicy.shouldMarkCompleted(
            reason: .completed,
            preview: false
        ))
        #expect(!OnboardingCompletionPolicy.shouldMarkCompleted(
            reason: .completed,
            preview: true
        ))
    }

    @Test func previewShowsThePersistedLiveTriggerButCannotApplyChanges() {
        #expect(OnboardingTriggerSelectionPolicy.initialValue(
            preview: true,
            persisted: .leftOption
        ) == .leftOption)
        #expect(!OnboardingTriggerSelectionPolicy.isEditable(preview: true))
        #expect(!OnboardingTriggerSelectionPolicy.appliesToApplication(preview: true))

        #expect(OnboardingTriggerSelectionPolicy.initialValue(
            preview: false,
            persisted: .leftOption
        ) == .leftOption)
        #expect(OnboardingTriggerSelectionPolicy.isEditable(preview: false))
        #expect(OnboardingTriggerSelectionPolicy.appliesToApplication(preview: false))
    }

    @Test func launchAtLoginSupportsBothDirections() {
        #expect(OnboardingLaunchAtLoginAction.required(
            currentlyEnabled: false,
            desired: false
        ) == .none)
        #expect(OnboardingLaunchAtLoginAction.required(
            currentlyEnabled: true,
            desired: true
        ) == .none)
        #expect(OnboardingLaunchAtLoginAction.required(
            currentlyEnabled: false,
            desired: true
        ) == .register)
        #expect(OnboardingLaunchAtLoginAction.required(
            currentlyEnabled: true,
            desired: false
        ) == .unregister)
    }
}
