import CoreFoundation
import XCTest
@testable import DictationKit

@MainActor
final class CommonRunLoopTimerTests: XCTestCase {
    func testRegistersInCommonModesAndPreservesSchedulingParameters() {
        var fireCount = 0
        let timer = CommonRunLoopTimer.schedule(
            after: 7,
            repeats: true,
            tolerance: 0.25
        ) { _ in
            fireCount += 1
        }
        defer { timer.invalidate() }

        XCTAssertTrue(timer.isValid)
        XCTAssertEqual(timer.timeInterval, 7)
        XCTAssertEqual(timer.tolerance, 0.25)
        XCTAssertTrue(CFRunLoopContainsTimer(
            CFRunLoopGetMain(),
            timer,
            .commonModes
        ))

        timer.fire()
        XCTAssertEqual(fireCount, 1)
    }
}
