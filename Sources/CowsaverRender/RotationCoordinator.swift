import Foundation

/// Something that wants to be told when to change what it shows.
public protocol RotationClient: AnyObject {
    /// Whether this registered client is still lifecycle-eligible for rotation.
    /// Production coordinators evaluate this on the main thread.
    var isLive: Bool { get }
    /// Called on the main thread.
    func rotate()
}

/// One application-managed rotation timer, shared by every registered client in a process.
///
/// A host may retain views beyond their displayed lifetime or create several views at once.
/// A timer owned by each view can therefore outlive its useful work.
///
/// Membership, effective interval, and the current timer generation are one locked state.
/// Removing the last member detaches that timer while holding the lock; cancellation after the
/// unlock still targets only the detached source, so it cannot stop a later generation. Timer
/// events and queued deliveries carry the generation that created them, while each registration
/// lifetime has its own token. Both identities must still be current before delivery begins.
///
/// The coordinator holds clients weakly. A timer tick captures the current weak memberships and
/// sends lifecycle evaluation and rotation to the main thread. Ineligible or deallocated clients
/// are then pruned, stopping or rescheduling the timer as one state transition. No client callback
/// runs while the coordinator lock is held.
///
/// Each client keeps the interval it asked for, and the timer runs at the shortest one any
/// registered client wants. Changing that effective interval replaces the timer generation, so
/// the next rotation is scheduled for roughly one full new interval from the change.
public final class RotationCoordinator {
    public static let shared = RotationCoordinator()

    private final class Membership {
        weak var client: RotationClient?
        var interval: TimeInterval
        let token: UInt64

        init(_ client: RotationClient, interval: TimeInterval, token: UInt64) {
            self.client = client
            self.interval = interval
            self.token = token
        }
    }

    private struct TimerState {
        let source: DispatchSourceTimer
        let generation: UInt64
    }

    typealias DeliveryScheduler = (@escaping () -> Void) -> Void
    typealias TimerCancellation = (DispatchSourceTimer) -> Void

    /// Used while no registered client asks for anything shorter.
    private static let defaultInterval: TimeInterval = 45

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.matthewsundling.cowsaver.rotation",
                                      qos: .utility)
    private let scheduleDelivery: DeliveryScheduler
    private let cancelTimer: TimerCancellation
    private var timer: TimerState?
    private var memberships: [Membership] = []
    private var interval: TimeInterval = RotationCoordinator.defaultInterval
    private var nextMembershipToken: UInt64 = 0
    private var nextTimerGeneration: UInt64 = 0

    /// Production delivery is asynchronous on the main queue. Synchronous delivery is retained
    /// as a narrow deterministic test seam for clients that do not access AppKit state.
    public convenience init(deliverOnMain: Bool = true) {
        if deliverOnMain {
            self.init(
                scheduleDelivery: { work in DispatchQueue.main.async(execute: work) },
                cancelTimer: { source in source.cancel() }
            )
        } else {
            self.init(
                scheduleDelivery: { work in work() },
                cancelTimer: { source in source.cancel() }
            )
        }
    }

    /// Internal seams let tests capture main delivery and delay physical cancellation without
    /// replacing the coordinator's state machine or timer implementation.
    init(
        scheduleDelivery: @escaping DeliveryScheduler,
        cancelTimer: @escaping TimerCancellation = { source in source.cancel() }
    ) {
        self.scheduleDelivery = scheduleDelivery
        self.cancelTimer = cancelTimer
    }

    deinit {
        lock.lock()
        let source = timer?.source
        timer = nil
        lock.unlock()
        if let source { cancelTimer(source) }
    }

    // MARK: Introspection for tests

    public var clientCount: Int {
        lock.lock(); defer { lock.unlock() }
        return memberships.compactMap(\.client).count
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return timer != nil
    }

    /// The interval the timer runs at: the shortest one any registered client asked for.
    public var effectiveInterval: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return interval
    }

    /// A narrow test seam for attributing a deterministic event to an old timer.
    var currentTimerGeneration: UInt64? {
        lock.lock(); defer { lock.unlock() }
        return timer?.generation
    }

    // MARK: Registration

    public func register(_ client: RotationClient, interval: TimeInterval) {
        lock.lock()
        pruneDeallocatedLocked()
        if let existing = memberships.first(where: { $0.client === client }) {
            existing.interval = interval
        } else {
            nextMembershipToken &+= 1
            memberships.append(Membership(client, interval: interval,
                                          token: nextMembershipToken))
        }
        let sourceToCancel = reconcileTimerLocked()
        lock.unlock()

        if let sourceToCancel { cancelTimer(sourceToCancel) }
    }

    /// Safe to call repeatedly from each lifecycle path that can detach a view.
    public func unregister(_ client: RotationClient) {
        lock.lock()
        memberships.removeAll { $0.client === client || $0.client == nil }
        let sourceToCancel = reconcileTimerLocked()
        lock.unlock()

        if let sourceToCancel { cancelTimer(sourceToCancel) }
    }

    // MARK: Timer

    /// Internal so tests can drive a current rotation deterministically.
    func tick() {
        lock.lock()
        let generation = timer?.generation
        lock.unlock()
        guard let generation else { return }
        tick(generation: generation)
    }

    /// Accept an event only while the timer generation that emitted it is still current.
    /// Internal so a test can deterministically invoke a canceled timer's late event.
    func tick(generation: UInt64) {
        lock.lock()
        guard timer?.generation == generation else {
            lock.unlock()
            return
        }

        pruneDeallocatedLocked()
        let sourceToCancel = reconcileTimerLocked()
        let deliveryGeneration = timer?.generation
        let captured = memberships
        lock.unlock()

        if let sourceToCancel { cancelTimer(sourceToCancel) }
        guard let deliveryGeneration, !captured.isEmpty else { return }

        scheduleDelivery { [weak self] in
            self?.deliver(captured, generation: deliveryGeneration)
        }
    }

    /// Evaluate real lifecycle state on the delivery queue, then atomically reject stale timer
    /// generations and membership lifetimes before any rotation callback begins.
    private func deliver(_ captured: [Membership], generation: UInt64) {
        lock.lock()
        let generationIsCurrent = timer?.generation == generation
        lock.unlock()
        guard generationIsCurrent else { return }

        let evaluated = captured.map { membership in
            (membership, membership.client, membership.client?.isLive == true)
        }

        lock.lock()
        guard timer?.generation == generation else {
            lock.unlock()
            return
        }

        let rejectedTokens = Set(evaluated.compactMap { membership, _, isLive in
            isLive ? nil : membership.token
        })
        if !rejectedTokens.isEmpty {
            memberships.removeAll { rejectedTokens.contains($0.token) }
        }
        let sourceToCancel = reconcileTimerLocked()
        let currentGeneration = timer?.generation
        let eligible = evaluated.compactMap { membership, client, isLive -> (Membership, RotationClient)? in
            guard isLive, let client,
                  memberships.contains(where: { $0 === membership && $0.token == membership.token })
            else { return nil }
            return (membership, client)
        }
        lock.unlock()

        if let sourceToCancel { cancelTimer(sourceToCancel) }
        guard let currentGeneration else { return }

        for (membership, client) in eligible {
            lock.lock()
            let mayBegin = timer?.generation == currentGeneration
                && memberships.contains(where: {
                    $0 === membership && $0.token == membership.token && $0.client === client
                })
            lock.unlock()
            guard mayBegin else { continue }
            client.rotate()
        }
    }

    /// Caller holds the lock. Nil weak references need no client callback and are safe to remove
    /// on the timer queue; real lifecycle state is evaluated later on the main delivery queue.
    private func pruneDeallocatedLocked() {
        memberships.removeAll { $0.client == nil }
    }

    /// Reconcile interval and timer identity with membership as one locked transition.
    ///
    /// The returned source is no longer current. Canceling it after the unlock cannot clear or
    /// cancel the timer installed by a later registration because cancellation targets the source
    /// directly rather than consulting coordinator state again.
    private func reconcileTimerLocked() -> DispatchSourceTimer? {
        let updatedInterval = memberships.map(\.interval).min()
            ?? RotationCoordinator.defaultInterval
        let intervalChanged = updatedInterval != interval
        interval = updatedInterval

        guard !memberships.isEmpty else {
            let detached = timer?.source
            timer = nil
            return detached
        }

        guard timer == nil || intervalChanged else { return nil }

        let detached = timer?.source
        nextTimerGeneration &+= 1
        let generation = nextTimerGeneration
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + updatedInterval,
                        repeating: updatedInterval,
                        leeway: .seconds(5))
        source.setEventHandler { [weak self] in self?.tick(generation: generation) }
        timer = TimerState(source: source, generation: generation)
        source.resume()
        return detached
    }
}
