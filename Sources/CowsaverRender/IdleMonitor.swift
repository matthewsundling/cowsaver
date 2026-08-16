import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Input idle time and display-sleep assertion status for the standalone app's `--idle` mode.
///
/// Used only by the standalone app's `--idle` mode. The `.saver` never needs this: the
/// system decides when a screensaver starts.
///
/// `CGEventSourceSecondsSinceLastEventType` provides the input timer without reading the
/// `IOHIDSystem` `HIDIdleTime` registry property directly.
///
/// Background: [XS-Labs on I/O Kit idle time](https://xs-labs.com/en/archives/articles/iokit-idle-time/)
/// documents the `HIDIdleTime` approach this avoids, and
/// [Apple DevForums 25509](https://developer.apple.com/forums/thread/25509) covers
/// `CGEventSourceSecondsSinceLastEventType` along with the video-playback caveat that
/// `displaySleepIsPrevented()` below exists to handle.
public enum IdleMonitor {
    /// Seconds since the user last did anything.
    ///
    /// Each event type carries its own timer, so this takes the minimum across all of
    /// them. Asking only about `.mouseMoved` would call a user idle while they typed.
    public static func secondsSinceLastInput() -> TimeInterval {
        let types: [CGEventType] = [
            .mouseMoved, .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .scrollWheel, .leftMouseDragged, .rightMouseDragged,
        ]
        let intervals = types.map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }
        return intervals.min() ?? 0
    }

    /// Whether something is actively holding the display awake.
    ///
    /// Video playback commonly holds one of these assertions while input idle time keeps
    /// increasing. The app therefore waits for both the configured idle interval and the
    /// absence of a display-sleep assertion.
    public static func displaySleepIsPrevented() -> Bool {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&assertions) == kIOReturnSuccess,
              let status = assertions?.takeRetainedValue() as? [String: Int] else {
            // If the status cannot be read, leave activation governed by input idle time.
            return false
        }

        let displayAssertions = [
            kIOPMAssertionTypeNoDisplaySleep as String,
            kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
        ]
        return displayAssertions.contains { (status[$0] ?? 0) > 0 }
    }

    /// Should the screensaver start now?
    public static func shouldActivate(afterIdleSeconds threshold: TimeInterval) -> Bool {
        guard threshold > 0 else { return false }
        guard secondsSinceLastInput() >= threshold else { return false }
        return !displaySleepIsPrevented()
    }
}
