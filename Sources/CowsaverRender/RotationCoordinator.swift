import Foundation

/// Something that wants to be told when to change what it shows.
public protocol RotationClient: AnyObject {
    /// Whether this client should receive future rotations. A view is live while it belongs
    /// to a window; the coordinator removes clients that are no longer live.
    var isLive: Bool { get }
    /// Called on the main thread.
    func rotate()
}

/// One application-managed rotation timer, shared by every registered client in a process.
///
/// A host may retain views beyond their displayed lifetime or create several views at once.
/// A timer owned by each view can therefore outlive its useful work.
///
/// So the relationship is inverted. The coordinator owns exactly one `DispatchSourceTimer`
/// and holds only **weak** references to its clients. Every tick:
///
///   1. drops clients that are `nil` *or* no longer `isLive` — the leaked-instance case,
///   2. cancels the timer outright if none remain,
///   3. otherwise delivers `rotate()` to the survivors.
///
/// Active views share one timer; detached views are pruned on the next tick. Explicit
/// teardown stops the timer immediately when the last client leaves.
///
/// Each client keeps the interval it asked for, and the timer runs at the shortest one any
/// live client wants. The host process outlives individual views, so that figure is derived
/// from the current membership rather than accumulated across it.
public final class RotationCoordinator {
    public static let shared = RotationCoordinator()

    private final class WeakClient {
        weak var value: RotationClient?
        var interval: TimeInterval
        init(_ value: RotationClient, interval: TimeInterval) {
            self.value = value
            self.interval = interval
        }
    }

    /// Used while no live client asks for anything shorter.
    private static let defaultInterval: TimeInterval = 45

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.matthewsundling.cowsaver.rotation",
                                      qos: .utility)
    private var timer: DispatchSourceTimer?
    private var clients: [WeakClient] = []
    private var interval: TimeInterval = RotationCoordinator.defaultInterval

    /// Whether `rotate()` is delivered on the main queue.
    ///
    /// Tests drive `tick()` directly and need the callbacks to land synchronously rather
    /// than on a main queue that is not running.
    private let deliversOnMain: Bool

    public init(deliverOnMain: Bool = true) {
        self.deliversOnMain = deliverOnMain
    }

    // MARK: Introspection for tests

    public var clientCount: Int {
        lock.lock(); defer { lock.unlock() }
        return clients.compactMap(\.value).filter(\.isLive).count
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return timer != nil
    }

    /// The interval the timer runs at: the shortest one any live client asked for.
    public var effectiveInterval: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return interval
    }

    // MARK: Registration

    public func register(_ client: RotationClient, interval: TimeInterval) {
        lock.lock()
        prune()
        if let existing = clients.first(where: { $0.value === client }) {
            existing.interval = interval
        } else {
            clients.append(WeakClient(client, interval: interval))
        }
        let changed = recomputeInterval()
        let shouldStart = timer == nil && !clients.isEmpty
        let running = changed ? timer : nil
        let seconds = self.interval
        lock.unlock()

        if shouldStart {
            startTimer()
        } else if let running {
            schedule(running, every: seconds)
        }
    }

    /// Safe to call repeatedly from each lifecycle path that can detach a view.
    public func unregister(_ client: RotationClient) {
        lock.lock()
        clients.removeAll { $0.value === client || $0.value == nil }
        let changed = recomputeInterval()
        let shouldStop = clients.isEmpty
        let running = changed ? timer : nil
        let seconds = self.interval
        lock.unlock()

        if shouldStop {
            stopTimer()
        } else if let running {
            schedule(running, every: seconds)
        }
    }

    // MARK: Timer

    private func startTimer() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        let seconds = interval
        let source = DispatchSource.makeTimerSource(queue: queue)
        schedule(source, every: seconds)
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        lock.unlock()
        source.resume()
    }

    /// Set the shared timer's cadence, on a new source or a running one.
    ///
    /// Generous leeway lets the OS coalesce our wakeups with others already scheduled. At a
    /// 45-second interval, five seconds of slack does not affect readability.
    ///
    /// Scheduling a running source again restarts its phase, so a changed interval also moves
    /// the next rotation to roughly one full interval from now.
    private func schedule(_ source: DispatchSourceTimer, every seconds: TimeInterval) {
        source.schedule(deadline: .now() + seconds,
                        repeating: seconds,
                        leeway: .seconds(5))
    }

    private func stopTimer() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    /// Internal so tests can drive a rotation deterministically.
    func tick() {
        lock.lock()
        prune()
        let live = clients.compactMap(\.value).filter(\.isLive)
        let empty = live.isEmpty
        let changed = recomputeInterval()
        let running = changed ? timer : nil
        let seconds = interval
        lock.unlock()

        // Stop the timer when pruning leaves no live clients.
        guard !empty else { stopTimer(); return }

        // Pruning can lengthen the effective interval; the running timer follows it.
        if let running { schedule(running, every: seconds) }

        let work = { for client in live where client.isLive { client.rotate() } }
        if deliversOnMain { DispatchQueue.main.async(execute: work) } else { work() }
    }

    /// Caller holds the lock.
    private func prune() {
        clients.removeAll { $0.value == nil || $0.value?.isLive == false }
    }

    /// Caller holds the lock. The shortest interval any live client asked for wins; they all
    /// rotate together. Nothing survives an empty membership, so the interval a later
    /// registration asks for takes effect on its own terms.
    ///
    /// Returns whether the effective interval changed.
    private func recomputeInterval() -> Bool {
        let requested = clients.compactMap { client -> TimeInterval? in
            guard let value = client.value, value.isLive else { return nil }
            return client.interval
        }
        let updated = requested.min() ?? RotationCoordinator.defaultInterval
        guard updated != interval else { return false }
        interval = updated
        return true
    }
}
