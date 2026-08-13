import Combine
import Foundation
import Sparkle

/// Owns Sparkle for the lifetime of the process. The updater is started only after
/// normal app launch so the XCTest host never performs network checks or opens UI.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    enum CheckState: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable
        case failure(String)
    }

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var checkState: CheckState = .idle
    @Published private(set) var availableUpdateVersion: String?
    @Published private(set) var isDownloadingUpdate = false
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var preparedUpdateVersion: String?
    @Published private(set) var isInstallingPreparedUpdate = false

    private lazy var userDriver = InlineUpdateUserDriver(owner: self)
    private lazy var updater = SPUUpdater(
        hostBundle: Bundle.main,
        applicationBundle: Bundle.main,
        userDriver: userDriver,
        delegate: self
    )
    private var observations: Set<AnyCancellable> = []
    private var manualProbeInProgress = false
    private var manualProbeFoundUpdate = false
    private var beginAvailableUpdateHandler: (() -> Void)?
    private var installWhenUserDriverFindsUpdate = false
    private var immediateInstallationHandler: (() -> Void)?
    private var expectedDownloadLength: UInt64?
    private var receivedDownloadLength: UInt64 = 0

    override init() {
        super.init()
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        // Automatic checks must reach the standard user driver so they can alert a
        // user who is not looking at Settings. Sparkle's automatic-download mode is
        // deliberately disabled because it silently stages an install-on-quit update
        // instead of reliably presenting that window.
        if updater.automaticallyDownloadsUpdates {
            updater.automaticallyDownloadsUpdates = false
        }

        updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
            .store(in: &observations)

        updater
            .publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.automaticallyChecksForUpdates = enabled
            }
            .store(in: &observations)
    }

    func start() {
        do {
            try updater.start()
        } catch {
            checkState = .failure("更新服务启动失败")
        }

#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-update-ready") {
            prepareUpdateForTesting(version: "1.3") {}
        }
#endif
    }

    func checkForUpdates() {
        guard !isCheckingForUpdates else { return }

        // An informational probe is ignored during any active update session and
        // provides no completion callback, so never put the inline UI into a checking
        // state in that case. Active downloads have their own persistent state/action.
        guard !updater.sessionInProgress else { return }
        guard updater.canCheckForUpdates else { return }
        guard let feedURL = Self.feedURL else {
            checkState = .failure("更新源配置不正确")
            return
        }

        checkState = .checking
        isCheckingForUpdates = true
        Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(
                    url: feedURL,
                    cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                    timeoutInterval: 10
                )
                request.httpMethod = "HEAD"
                request.setValue("application/xml", forHTTPHeaderField: "Accept")
                let (_, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode
                guard let statusCode, 200..<300 ~= statusCode else {
                    checkState = .failure(Self.feedErrorMessage(statusCode: statusCode))
                    isCheckingForUpdates = false
                    return
                }

                // A scheduled check may have started while the network preflight was
                // awaiting. Re-read Sparkle directly instead of trusting the KVO mirror,
                // whose main-run-loop delivery can lag behind the real session state.
                guard !updater.sessionInProgress,
                      updater.canCheckForUpdates else {
                    checkState = .idle
                    isCheckingForUpdates = false
                    return
                }

                // Probe first so the Settings row owns the "already up to date" and
                // error states. Finding an update leaves one explicit action in our
                // Settings and menu instead of opening a second Sparkle window.
                manualProbeInProgress = true
                manualProbeFoundUpdate = false
                updater.checkForUpdateInformation()
            } catch {
                checkState = .failure(Self.feedErrorMessage(statusCode: nil))
                isCheckingForUpdates = false
            }
        }
    }

    var automaticUpdatesEnabled: Bool {
        automaticallyChecksForUpdates
    }

    func setAutomaticUpdatesEnabled(_ enabled: Bool) {
        updater.automaticallyDownloadsUpdates = false
        updater.automaticallyChecksForUpdates = enabled
    }

    /// Starts downloading the update already found by the informational probe.
    /// The custom user driver answers Sparkle's ensuing install choice directly, so
    /// one click begins the update without opening Sparkle's separate modal window.
    func installAvailableUpdate() {
        guard !isDownloadingUpdate, preparedUpdateVersion == nil,
              availableUpdateVersion != nil else { return }

        isDownloadingUpdate = true
        downloadProgress = nil
        if let beginAvailableUpdateHandler {
            self.beginAvailableUpdateHandler = nil
            beginAvailableUpdateHandler()
        } else {
            installWhenUserDriverFindsUpdate = true
            updater.checkForUpdates()
        }
    }

    /// Installs the update Sparkle has already downloaded and verified. Keeping the
    /// handler owned here lets the menu and Settings share one explicit action without
    /// opening Sparkle's modal update window.
    func installPreparedUpdate() {
        guard !isInstallingPreparedUpdate,
              let immediateInstallationHandler else { return }
        isInstallingPreparedUpdate = true
        immediateInstallationHandler()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        if manualProbeInProgress {
            availableUpdateVersion = item.displayVersionString
            checkState = .updateAvailable
            manualProbeFoundUpdate = true
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        guard manualProbeInProgress else { return }
        checkState = Self.noUpdateState(error)
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        guard Self.shouldFinishManualProbe(
            updateCheck,
            manualProbeInProgress: manualProbeInProgress
        ) else { return }

        manualProbeInProgress = false
        isCheckingForUpdates = false
        if manualProbeFoundUpdate {
            manualProbeFoundUpdate = false
        } else if let error, checkState == .checking {
            checkState = .failure(Self.updateErrorMessage(error))
        }
    }

#if DEBUG
    func makeUpdateAvailableForTesting(version: String, handler: @escaping () -> Void) {
        availableUpdateVersion = version
        beginAvailableUpdateHandler = handler
        isDownloadingUpdate = false
        downloadProgress = nil
        preparedUpdateVersion = nil
    }

    func updateDownloadProgressForTesting(expected: UInt64, received: [UInt64]) {
        downloadDidStart()
        downloadExpectedLength(expected)
        for length in received { downloadReceived(length) }
    }

    func prepareUpdateForTesting(version: String, handler: @escaping () -> Void) {
        availableUpdateVersion = version
        isDownloadingUpdate = false
        downloadProgress = nil
        preparedUpdateVersion = version
        immediateInstallationHandler = handler
        isInstallingPreparedUpdate = false
    }
#endif

    // MARK: - Inline Sparkle user driver

    fileprivate func userDriverFoundUpdate(
        _ item: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        availableUpdateVersion = item.displayVersionString
        checkState = .updateAvailable

        if installWhenUserDriverFindsUpdate {
            installWhenUserDriverFindsUpdate = false
            beginAvailableUpdateHandler = nil
            isDownloadingUpdate = true
            reply(.install)
        } else {
            beginAvailableUpdateHandler = { reply(.install) }
            isDownloadingUpdate = false
        }
    }

    fileprivate func userDriverCheckStarted() {
        if installWhenUserDriverFindsUpdate {
            isDownloadingUpdate = true
            downloadProgress = nil
        }
    }

    fileprivate func userDriverDidNotFindUpdate(_ error: Error) {
        clearAvailableUpdate()
        checkState = Self.noUpdateState(error)
    }

    fileprivate func userDriverFailed(_ error: Error) {
        installWhenUserDriverFindsUpdate = false
        isDownloadingUpdate = false
        downloadProgress = nil
        checkState = .failure(Self.updateErrorMessage(error))
    }

    fileprivate func downloadDidStart() {
        isDownloadingUpdate = true
        expectedDownloadLength = nil
        receivedDownloadLength = 0
        downloadProgress = nil
    }

    fileprivate func downloadExpectedLength(_ length: UInt64) {
        expectedDownloadLength = length > 0 ? length : nil
        updateDownloadProgress()
    }

    fileprivate func downloadReceived(_ length: UInt64) {
        receivedDownloadLength &+= length
        updateDownloadProgress()
    }

    fileprivate func extractionDidStart() {
        isDownloadingUpdate = true
        downloadProgress = nil
    }

    fileprivate func readyToInstall(
        _ reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        isDownloadingUpdate = false
        downloadProgress = nil
        preparedUpdateVersion = availableUpdateVersion
        immediateInstallationHandler = { reply(.install) }
    }

    fileprivate func installationDidStart() {
        isInstallingPreparedUpdate = true
    }

    fileprivate func dismissUpdateSession() {
        installWhenUserDriverFindsUpdate = false
        beginAvailableUpdateHandler = nil
        if preparedUpdateVersion == nil {
            isDownloadingUpdate = false
            downloadProgress = nil
        }
    }

    private func clearAvailableUpdate() {
        availableUpdateVersion = nil
        beginAvailableUpdateHandler = nil
        installWhenUserDriverFindsUpdate = false
        isDownloadingUpdate = false
        downloadProgress = nil
        expectedDownloadLength = nil
        receivedDownloadLength = 0
    }

    private func updateDownloadProgress() {
        guard let expectedDownloadLength, expectedDownloadLength > 0 else {
            downloadProgress = nil
            return
        }
        downloadProgress = min(Double(receivedDownloadLength) / Double(expectedDownloadLength), 1)
    }

    static var displayVersion: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(shortVersion) (\(build))"
    }

    static func feedErrorMessage(statusCode: Int?) -> String {
        statusCode == 404 ? "更新源尚未发布" : "暂时无法连接更新服务器"
    }

    static func updateErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        return nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.noUpdateError.rawValue
            ? noUpdateMessage(nsError)
            : "检查更新失败，请稍后重试"
    }

    static func noUpdateState(_ error: Error) -> CheckState {
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain,
              nsError.code == SUError.noUpdateError.rawValue else {
            return .failure("检查更新失败，请稍后重试")
        }

        let message = noUpdateMessage(nsError)
        return message == "已是最新版本" ? .upToDate : .failure(message)
    }

    private static func noUpdateMessage(_ error: NSError) -> String {
        guard let reason = error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber else {
            // Older Sparkle versions and synthetic errors may omit the reason. Preserve
            // the historical no-update meaning while using explicit reasons when present.
            return "已是最新版本"
        }
        switch reason.int32Value {
        case SPUNoUpdateFoundReason.onLatestVersion.rawValue,
             SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue:
            return "已是最新版本"
        case SPUNoUpdateFoundReason.systemIsTooOld.rawValue:
            return "有新版本，但需要更高版本的 macOS"
        case SPUNoUpdateFoundReason.systemIsTooNew.rawValue:
            return "新版本暂不支持当前 macOS"
        case SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue:
            return "新版本不支持这台 Mac"
        default:
            return "没有适用于这台 Mac 的更新"
        }
    }

    static func shouldFinishManualProbe(
        _ updateCheck: SPUUpdateCheck,
        manualProbeInProgress: Bool
    ) -> Bool {
        manualProbeInProgress && updateCheck == .updateInformation
    }

    static func shouldUseStandardUI(userInitiated: Bool) -> Bool {
        !userInitiated
    }

    private static var feedURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
            .flatMap(URL.init(string:))
    }
}

/// Routes explicit user checks into Settings and the menu, while scheduled background
/// checks retain Sparkle's standard window so updates are visible outside those surfaces.
@MainActor
private final class InlineUpdateUserDriver: NSObject, SPUUserDriver {
    private weak var owner: AppUpdater?
    private let standardDriver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
    private var usesStandardDriver = false

    init(owner: AppUpdater) {
        self.owner = owner
    }

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        standardDriver.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        usesStandardDriver = false
        owner?.userDriverCheckStarted()
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        usesStandardDriver = AppUpdater.shouldUseStandardUI(userInitiated: state.userInitiated)
        if usesStandardDriver {
            standardDriver.showUpdateFound(with: appcastItem, state: state, reply: reply)
        } else {
            owner?.userDriverFoundUpdate(appcastItem, state: state, reply: reply)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        if usesStandardDriver {
            standardDriver.showUpdateReleaseNotes(with: downloadData)
        }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        if usesStandardDriver {
            standardDriver.showUpdateReleaseNotesFailedToDownloadWithError(error)
        }
    }

    func showUpdateNotFoundWithError(
        _ error: Error,
        acknowledgement: @escaping () -> Void
    ) {
        if usesStandardDriver {
            standardDriver.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
        } else {
            owner?.userDriverDidNotFindUpdate(error)
            acknowledgement()
        }
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if usesStandardDriver {
            standardDriver.showUpdaterError(error, acknowledgement: acknowledgement)
        } else {
            owner?.userDriverFailed(error)
            acknowledgement()
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        if usesStandardDriver {
            standardDriver.showDownloadInitiated(cancellation: cancellation)
        } else {
            owner?.downloadDidStart()
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        if usesStandardDriver {
            standardDriver.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
        } else {
            owner?.downloadExpectedLength(expectedContentLength)
        }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        if usesStandardDriver {
            standardDriver.showDownloadDidReceiveData(ofLength: length)
        } else {
            owner?.downloadReceived(length)
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        if usesStandardDriver {
            standardDriver.showDownloadDidStartExtractingUpdate()
        } else {
            owner?.extractionDidStart()
        }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        if usesStandardDriver {
            standardDriver.showExtractionReceivedProgress(progress)
        }
    }

    func showReady(
        toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        if usesStandardDriver {
            standardDriver.showReady(toInstallAndRelaunch: reply)
        } else {
            owner?.readyToInstall(reply)
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        if usesStandardDriver {
            standardDriver.showInstallingUpdate(
                withApplicationTerminated: applicationTerminated,
                retryTerminatingApplication: retryTerminatingApplication
            )
        } else {
            owner?.installationDidStart()
        }
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        if usesStandardDriver {
            standardDriver.showUpdateInstalledAndRelaunched(
                relaunched,
                acknowledgement: acknowledgement
            )
        } else {
            acknowledgement()
        }
    }

    func dismissUpdateInstallation() {
        if usesStandardDriver {
            standardDriver.dismissUpdateInstallation()
        } else {
            owner?.dismissUpdateSession()
        }
        usesStandardDriver = false
    }

    func showUpdateInFocus() {
        if usesStandardDriver {
            standardDriver.showUpdateInFocus()
        }
    }
}
