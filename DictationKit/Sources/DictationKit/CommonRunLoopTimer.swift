import Foundation

/// Schedules wall-clock deadlines on the main run loop without pausing them
/// while AppKit is tracking a menu, modal control, or drag.
///
/// `Timer.scheduledTimer` registers only in the default mode. That is suitable
/// for animation-like work that should pause during event tracking, but not for
/// transport deadlines, session expiry, keep-alive probes, or recording safety
/// limits whose meaning is elapsed real time.
public enum CommonRunLoopTimer {
    @discardableResult
    public static func schedule(
        after interval: TimeInterval,
        repeats: Bool,
        tolerance: TimeInterval? = nil,
        _ action: @escaping (Timer) -> Void
    ) -> Timer {
        let timer = Timer(
            timeInterval: interval,
            repeats: repeats,
            block: action
        )
        if let tolerance {
            timer.tolerance = tolerance
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
