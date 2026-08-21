import Foundation
import Testing
@testable import CowsaverRender

private final class TestClient: RotationClient {
    var isLive = true
    private(set) var rotations = 0
    func rotate() { rotations += 1 }
}

private final class DeliveryCapture {
    private(set) var pending: [() -> Void] = []

    func schedule(_ work: @escaping () -> Void) {
        pending.append(work)
    }

    func runNext() {
        pending.removeFirst()()
    }
}

private final class CancellationCapture {
    private(set) var pending: [DispatchSourceTimer] = []

    func cancelLater(_ source: DispatchSourceTimer) {
        pending.append(source)
    }

    func runNext() {
        pending.removeFirst().cancel()
    }
}

/// The coordinator owns the application's recurring rotation work. These tests verify that
/// detached clients do not retain a timer.
///
/// Rotation is delivered synchronously here (`deliverOnMain: false`) and `tick()` is driven
/// by hand, so none of this depends on wall-clock time or a running main loop.
@Suite("Rotation coordinator")
struct RotationCoordinatorTests {
    @Test func startsATimerOnFirstRegistrationAndStopsOnLastUnregister() {
        let coordinator = RotationCoordinator(deliverOnMain: false)
        let client = TestClient()

        #expect(!coordinator.isRunning)
        coordinator.register(client, interval: 3600)
        #expect(coordinator.isRunning)
        #expect(coordinator.clientCount == 1)

        coordinator.unregister(client)
        #expect(!coordinator.isRunning)
        #expect(coordinator.clientCount == 0)
    }

    /// Active clients share one rotation timer rather than each owning a timer.
    @Test func manyClientsShareOneTimer() {
        let coordinator = RotationCoordinator(deliverOnMain: false)
        let clients = (0 ..< 10).map { _ in TestClient() }
        for client in clients { coordinator.register(client, interval: 3600) }

        #expect(coordinator.clientCount == 10)
        #expect(coordinator.isRunning)

        coordinator.tick()
        for client in clients { #expect(client.rotations == 1) }
    }

    @Test func registeringTwiceDoesNotDuplicateTheClient() {
        let coordinator = RotationCoordinator(deliverOnMain: false)
        let client = TestClient()
        coordinator.register(client, interval: 3600)
        coordinator.register(client, interval: 3600)
        #expect(coordinator.clientCount == 1)

        coordinator.tick()
        #expect(client.rotations == 1, "a duplicated client would rotate twice per tick")
    }

    /// A client that has left its window is pruned even if it was not explicitly unregistered.
    @Test func prunesClientsThatAreNoLongerLive() {
        let coordinator = RotationCoordinator(deliverOnMain: false)
        let live = TestClient()
        let leaked = TestClient()
        coordinator.register(live, interval: 3600)
        coordinator.register(leaked, interval: 3600)

        leaked.isLive = false
        coordinator.tick()

        #expect(live.rotations == 1)
        #expect(leaked.rotations == 0, "a detached client must never be rotated again")
        #expect(coordinator.clientCount == 1)
    }

    /// When pruning removes every client, the next tick cancels the timer.
    @Test func timerStopsItselfWhenEveryClientGoesAway() {
        let coordinator = RotationCoordinator(deliverOnMain: false)
        let client = TestClient()
        coordinator.register(client, interval: 3600)
        #expect(coordinator.isRunning)

        client.isLive = false          // simulate the view losing its window
        coordinator.tick()             // nobody called unregister

        #expect(!coordinator.isRunning, "the timer must stop itself, not wait to be told")
        #expect(coordinator.clientCount == 0)
    }

    /// Clients are held weakly, so a deallocated view cannot keep the timer alive.
    @Test func holdsClientsWeakly() {
        let coordinator = RotationCoordinator(deliverOnMain: false)
        do {
            let temporary = TestClient()
            coordinator.register(temporary, interval: 3600)
            #expect(coordinator.clientCount == 1)
        }
        #expect(coordinator.clientCount == 0, "the client was not released")
        coordinator.tick()
        #expect(!coordinator.isRunning)
    }

    /// Teardown is called from `stopAnimation()`, `deinit`, and `viewDidMoveToWindow`.
    /// All three firing must be harmless.
    @Test func unregisteringRepeatedlyIsSafe() {
        let coordinator = RotationCoordinator(deliverOnMain: false)
        let client = TestClient()
        coordinator.register(client, interval: 3600)
        coordinator.unregister(client)
        coordinator.unregister(client)
        coordinator.unregister(client)
        #expect(coordinator.clientCount == 0)
        #expect(!coordinator.isRunning)
    }

    @Test func tickOnAnEmptyCoordinatorDoesNothing() {
        let coordinator = RotationCoordinator(deliverOnMain: false)
        coordinator.tick()
        #expect(!coordinator.isRunning)
    }

    // MARK: Stale work

    /// Delaying physical cancellation models the former interval between deciding to stop and
    /// actually stopping. A registration made in that interval must install a new timer, and the
    /// delayed operation must remain tied to the detached old source.
    @Test func obsoleteCancellationCannotStopANewRegistration() {
        let deliveries = DeliveryCapture()
        let cancellations = CancellationCapture()
        let coordinator = RotationCoordinator(
            scheduleDelivery: deliveries.schedule,
            cancelTimer: cancellations.cancelLater
        )
        let departed = TestClient()
        let current = TestClient()

        coordinator.register(departed, interval: 5)
        let oldGeneration = coordinator.currentTimerGeneration
        coordinator.unregister(departed)
        #expect(cancellations.pending.count == 1)

        coordinator.register(current, interval: 40)
        let newGeneration = coordinator.currentTimerGeneration
        #expect(newGeneration != oldGeneration)

        cancellations.runNext()
        #expect(coordinator.isRunning)
        #expect(coordinator.effectiveInterval == 40)
        #expect(coordinator.currentTimerGeneration == newGeneration)

        coordinator.tick()
        #expect(deliveries.pending.count == 1)
        deliveries.runNext()
        #expect(current.rotations == 1)

        coordinator.unregister(current)
        cancellations.runNext()
    }

    @Test func capturedDeliveryDoesNotRotateAfterUnregister() {
        let deliveries = DeliveryCapture()
        let coordinator = RotationCoordinator(scheduleDelivery: deliveries.schedule)
        let client = TestClient()
        coordinator.register(client, interval: 3600)

        coordinator.tick()
        #expect(deliveries.pending.count == 1)
        coordinator.unregister(client)
        deliveries.runNext()

        #expect(client.rotations == 0)
        #expect(!coordinator.isRunning)
    }

    /// The old queued block retains the old membership token, even though object identity is the
    /// same after re-registration. Only work captured for the new lifetime may rotate it.
    @Test func reRegisteringSameObjectDoesNotReviveOldDelivery() {
        let deliveries = DeliveryCapture()
        let coordinator = RotationCoordinator(scheduleDelivery: deliveries.schedule)
        let anchor = TestClient()
        let client = TestClient()
        coordinator.register(anchor, interval: 5)
        coordinator.register(client, interval: 20)

        coordinator.tick()
        coordinator.unregister(client)
        coordinator.register(client, interval: 40)
        deliveries.runNext()

        #expect(client.rotations == 0)
        #expect(anchor.rotations == 1)
        #expect(coordinator.clientCount == 2)
        #expect(coordinator.effectiveInterval == 5)

        coordinator.unregister(anchor)
        #expect(coordinator.effectiveInterval == 40)

        coordinator.tick()
        deliveries.runNext()
        #expect(client.rotations == 1)

        coordinator.unregister(client)
    }

    @Test func canceledTimerGenerationCannotReachNewMembership() {
        let coordinator = RotationCoordinator(deliverOnMain: false)
        let departed = TestClient()
        let current = TestClient()
        coordinator.register(departed, interval: 5)
        let oldGeneration = coordinator.currentTimerGeneration

        coordinator.unregister(departed)
        coordinator.register(current, interval: 40)
        let newGeneration = coordinator.currentTimerGeneration

        if let oldGeneration { coordinator.tick(generation: oldGeneration) }
        #expect(current.rotations == 0)
        #expect(coordinator.currentTimerGeneration == newGeneration)
        #expect(coordinator.effectiveInterval == 40)

        if let newGeneration { coordinator.tick(generation: newGeneration) }
        #expect(current.rotations == 1)

        coordinator.unregister(current)
    }

    @Test func capturedClientThatBecomesIneligibleIsPruned() {
        let deliveries = DeliveryCapture()
        let coordinator = RotationCoordinator(scheduleDelivery: deliveries.schedule)
        let client = TestClient()
        coordinator.register(client, interval: 3600)
        coordinator.tick()

        client.isLive = false
        deliveries.runNext()

        #expect(client.rotations == 0)
        #expect(coordinator.clientCount == 0)
        #expect(!coordinator.isRunning)
        #expect(coordinator.effectiveInterval == 45)
    }

    // MARK: Effective interval

    /// The screensaver host outlives the views it creates. A short interval from an earlier
    /// activation must not survive into a later one that asks for a longer one.
    @Test func aDepartedClientLeavesNoIntervalBehind() {
        let coordinator = RotationCoordinator(deliverOnMain: false)
        let first = TestClient()
        coordinator.register(first, interval: 5)
        #expect(coordinator.effectiveInterval == 5)

        coordinator.unregister(first)
        let second = TestClient()
        coordinator.register(second, interval: 40)

        #expect(coordinator.effectiveInterval == 40, "the departed client still set the pace")
    }

    /// Pruning is a membership change like any other, so it also lengthens the interval again.
    @Test func pruningAShortIntervalClientRestoresTheLongerInterval() {
        let coordinator = RotationCoordinator(deliverOnMain: false)
        let patient = TestClient()
        let hurried = TestClient()
        coordinator.register(patient, interval: 40)
        coordinator.register(hurried, interval: 5)
        #expect(coordinator.effectiveInterval == 5)

        hurried.isLive = false
        coordinator.tick()

        #expect(coordinator.effectiveInterval == 40)
        #expect(coordinator.clientCount == 1)
    }

    /// A view whose settings changed re-registers rather than creating a second client.
    @Test func reRegisteringTheSameClientUpdatesItsInterval() {
        let coordinator = RotationCoordinator(deliverOnMain: false)
        let client = TestClient()
        coordinator.register(client, interval: 5)
        #expect(coordinator.effectiveInterval == 5)

        coordinator.register(client, interval: 40)

        #expect(coordinator.effectiveInterval == 40)
        #expect(coordinator.clientCount == 1)
    }
}
