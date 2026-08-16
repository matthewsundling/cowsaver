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
public final class RotationCoordinator {
    public static let shared = RotationCoordinator()

    private final class WeakClient {
        weak var value: RotationClient?
        init(_ value: RotationClient) { self.value = value }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.matthewsundling.cowsaver.rotation",
                                      qos: .utility)
    private var timer: DispatchSourceTimer?
    private var clients: [WeakClient] = []
    private var interval: TimeInterval = 45

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

    // MARK: Registration

    public func register(_ client: RotationClient, interval: TimeInterval) {
        lock.lock()
        prune()
        if !clients.contains(where: { $0.value === client }) {
            clients.append(WeakClient(client))
        }
        // The shortest interval any client asked for wins; they all rotate together.
        self.interval = clients.isEmpty ? interval : min(self.interval, interval)
        let shouldStart = timer == nil && !clients.isEmpty
        lock.unlock()

        if shouldStart { startTimer() }
    }

    /// Safe to call repeatedly from each lifecycle path that can detach a view.
    public func unregister(_ client: RotationClient) {
        lock.lock()
        clients.removeAll { $0.value === client || $0.value == nil }
        let shouldStop = clients.isEmpty
        lock.unlock()

        if shouldStop { stopTimer() }
    }

    // MARK: Timer

    private func startTimer() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        let seconds = interval
        let source = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway lets the OS coalesce our wakeups with others already scheduled.
        // At a 45-second interval, five seconds of slack does not affect readability.
        source.schedule(deadline: .now() + seconds,
                        repeating: seconds,
                        leeway: .seconds(5))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        lock.unlock()
        source.resume()
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
        lock.unlock()

        // Stop the timer when pruning leaves no live clients.
        guard !empty else { stopTimer(); return }

        let work = { for client in live where client.isLive { client.rotate() } }
        if deliversOnMain { DispatchQueue.main.async(execute: work) } else { work() }
    }

    /// Caller holds the lock.
    private func prune() {
        clients.removeAll { $0.value == nil || $0.value?.isLive == false }
    }
}
