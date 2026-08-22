import CowsaverAppSupport
import Testing

@Suite("Idle monitor")
struct IdleMonitorTests {
    /// Cannot assert a value — it depends on whoever is at the keyboard — but it must
    /// return something sane rather than a negative or absurd number.
    @Test func reportsAPlausibleIdleTime() {
        let seconds = IdleMonitor.secondsSinceLastInput()
        #expect(seconds >= 0)
        #expect(seconds < 60 * 60 * 24 * 365)
    }

    @Test func doesNotActivateOnAZeroThreshold() {
        #expect(!IdleMonitor.shouldActivate(afterIdleSeconds: 0))
        #expect(!IdleMonitor.shouldActivate(afterIdleSeconds: -1))
    }

    /// A threshold nobody could have reached must never fire.
    @Test func doesNotActivateBelowTheThreshold() {
        #expect(!IdleMonitor.shouldActivate(afterIdleSeconds: 60 * 60 * 24 * 365))
    }

    @Test func assertionCheckDoesNotCrash() {
        _ = IdleMonitor.displaySleepIsPrevented()
    }
}
