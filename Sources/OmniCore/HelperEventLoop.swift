import Foundation
import CoreFoundation

/// Cooperative delay for the command-line helper. The state machine suspends its
/// next step while this thread services its run-loop sources, timers and queued
/// notifications. Private display calls stay on their existing calling thread.
/// No callbacks here perform display writes or start another transaction.
public enum HelperEventLoop {
    public static func wait(_ interval: TimeInterval) {
        guard interval.isFinite, interval > 0 else { return }
        let end = ProcessInfo.processInfo.systemUptime + interval
        let loop = CFRunLoopGetCurrent()
        // An empty CLI run loop can return immediately. A one-shot timer keeps
        // the source set nonempty without falling back to Thread.sleep.
        let keepAlive = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + interval, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(loop, keepAlive, .defaultMode)
        defer { CFRunLoopTimerInvalidate(keepAlive) }
        while true {
            let remaining = end - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return }
            _ = CFRunLoopRunInMode(.defaultMode, remaining, false)
        }
    }
}
