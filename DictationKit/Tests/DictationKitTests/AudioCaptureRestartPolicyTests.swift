import XCTest
@testable import DictationKit

final class AudioCaptureRestartPolicyTests: XCTestCase {
    private let attempt = AudioCaptureRestartAttempt(
        captureGeneration: 41,
        restartEpoch: 7
    )

    func testWatchdogReportsCurrentRestartThatDeliveredNoBuffers() {
        XCTAssertTrue(AudioCaptureRestartPolicy.shouldReportStalledCapture(
            attempt,
            activeCaptureGeneration: 41,
            currentRestartEpoch: 7,
            deliveredBuffersBefore: 100,
            deliveredBuffersNow: 100,
            isRunning: true,
            captureFailureReported: false
        ))
    }

    func testWatchdogFromOldGestureCannotFailNewCapture() {
        XCTAssertFalse(AudioCaptureRestartPolicy.shouldReportStalledCapture(
            attempt,
            activeCaptureGeneration: 42,
            currentRestartEpoch: 7,
            deliveredBuffersBefore: 100,
            deliveredBuffersNow: 100,
            isRunning: true,
            captureFailureReported: false
        ))
    }

    func testWatchdogFromEarlierRestartCannotFailLaterRestartInSameCapture() {
        XCTAssertFalse(AudioCaptureRestartPolicy.shouldReportStalledCapture(
            attempt,
            activeCaptureGeneration: 41,
            currentRestartEpoch: 8,
            deliveredBuffersBefore: 100,
            deliveredBuffersNow: 100,
            isRunning: true,
            captureFailureReported: false
        ))
    }

    func testWatchdogIgnoresRestartThatDeliveredAudio() {
        XCTAssertFalse(AudioCaptureRestartPolicy.shouldReportStalledCapture(
            attempt,
            activeCaptureGeneration: 41,
            currentRestartEpoch: 7,
            deliveredBuffersBefore: 100,
            deliveredBuffersNow: 101,
            isRunning: true,
            captureFailureReported: false
        ))
    }

    func testDeferredRestartTokenRequiresBothGenerationAndEpoch() {
        XCTAssertTrue(AudioCaptureRestartPolicy.isCurrent(
            attempt,
            activeCaptureGeneration: 41,
            currentRestartEpoch: 7
        ))
        XCTAssertFalse(AudioCaptureRestartPolicy.isCurrent(
            attempt,
            activeCaptureGeneration: 42,
            currentRestartEpoch: 7
        ))
        XCTAssertFalse(AudioCaptureRestartPolicy.isCurrent(
            attempt,
            activeCaptureGeneration: 41,
            currentRestartEpoch: 8
        ))
    }

    func testConfigurationDrainPublishesOnlyANewlyLatchedFailure() {
        XCTAssertEqual(
            AudioCaptureRestartPolicy.newlyLatchedFailureGeneration(
                wasReported: false,
                isReported: true,
                activeCaptureGeneration: 41
            ),
            41
        )
        XCTAssertNil(AudioCaptureRestartPolicy.newlyLatchedFailureGeneration(
            wasReported: true,
            isReported: true,
            activeCaptureGeneration: 41
        ))
        XCTAssertNil(AudioCaptureRestartPolicy.newlyLatchedFailureGeneration(
            wasReported: false,
            isReported: false,
            activeCaptureGeneration: 41
        ))
        XCTAssertNil(AudioCaptureRestartPolicy.newlyLatchedFailureGeneration(
            wasReported: false,
            isReported: true,
            activeCaptureGeneration: nil
        ))
    }
}
