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
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var checkState: CheckState = .idle

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var observations: Set<AnyCancellable> = []
    private var manualProbeInProgress = false
    private var manualProbeFoundUpdate = false

    override init() {
        super.init()
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates

        // Older builds exposed these as two separate switches. The merged control
        // follows the user's automatic-install choice and quietly brings checking
        // into the same state, so an existing preference cannot appear half-on.
        if automaticallyChecksForUpdates != automaticallyDownloadsUpdates {
            controller.updater.automaticallyChecksForUpdates = automaticallyDownloadsUpdates
            automaticallyChecksForUpdates = automaticallyDownloadsUpdates
        }

        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
            .store(in: &observations)

        controller.updater
            .publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.automaticallyChecksForUpdates = enabled
            }
            .store(in: &observations)

        controller.updater
            .publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.automaticallyDownloadsUpdates = enabled
            }
            .store(in: &observations)
    }

    func start() {
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard !isCheckingForUpdates else { return }

        // Sparkle intentionally reports that a user check is possible while its update
        // window is visible: invoking the normal action focuses that existing window.
        // An informational probe, on the other hand, is ignored during any active
        // session and provides no completion callback, so never put our inline UI into
        // a checking state in that case.
        if controller.updater.sessionInProgress {
            controller.checkForUpdates(nil)
            return
        }
        guard controller.updater.canCheckForUpdates else { return }
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
                guard !controller.updater.sessionInProgress,
                      controller.updater.canCheckForUpdates else {
                    checkState = .idle
                    isCheckingForUpdates = false
                    return
                }

                // Probe first so the Settings row owns the "already up to date" and
                // error states. Sparkle's standard UI is shown only when there is an
                // update worth presenting.
                manualProbeInProgress = true
                manualProbeFoundUpdate = false
                controller.updater.checkForUpdateInformation()
            } catch {
                checkState = .failure(Self.feedErrorMessage(statusCode: nil))
                isCheckingForUpdates = false
            }
        }
    }

    var automaticUpdatesEnabled: Bool {
        automaticallyChecksForUpdates && automaticallyDownloadsUpdates
    }

    func setAutomaticUpdatesEnabled(_ enabled: Bool) {
        if enabled {
            controller.updater.automaticallyChecksForUpdates = true
            controller.updater.automaticallyDownloadsUpdates = true
        } else {
            controller.updater.automaticallyDownloadsUpdates = false
            controller.updater.automaticallyChecksForUpdates = false
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard manualProbeInProgress else { return }
        checkState = .updateAvailable
        manualProbeFoundUpdate = true
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
            controller.checkForUpdates(nil)
        } else if let error, checkState == .checking {
            checkState = .failure(Self.updateErrorMessage(error))
        }
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

    private static var feedURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
            .flatMap(URL.init(string:))
    }
}
