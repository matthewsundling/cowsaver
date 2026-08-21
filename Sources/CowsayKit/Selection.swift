import Foundation

/// A small, seedable PRNG.
///
/// Seedable matters twice here: the tests need deterministic sequences, and each
/// screensaver view seeds its own so two displays do not show the same fortune at the same
/// moment. `SystemRandomNumberGenerator` gives neither.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { self.state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Random selection that excludes every element in its recent-history window.
///
/// Each pick samples directly from the eligible elements, so applying history preserves the
/// active policy instead of depending on random retries or array order.
public struct NoRepeatSelector<Element> {
    private enum Policy {
        case uniformRecords
        case weightedRecords([Int])
        case equalSources([String])
    }

    private let elements: [Element]
    private let policy: Policy
    private var history: [Int] = []
    private let historySize: Int
    private var generator: SplitMix64

    // A narrow deterministic seam for tests. Production selectors leave this empty.
    private let controlledRolls: [Double]
    private var controlledRollIndex = 0

    public var isEmpty: Bool { elements.isEmpty }
    public var count: Int { elements.count }

    /// - Parameters:
    ///   - historyLimit: how many recent picks to exclude. Clamped to `count - 1`, so a
    ///     small corpus still makes progress instead of deadlocking.
    ///   - weights: per-element weights. Positive eligible weights are sampled
    ///     proportionally; zero and negative weights are excluded while any positive eligible
    ///     weight remains. `nil`, count-mismatched, or entirely non-positive weights select
    ///     uniformly.
    public init(
        elements: [Element],
        historyLimit: Int = 20,
        seed: UInt64,
        weights: [Int]? = nil
    ) {
        let policy: Policy
        if let weights, weights.count == elements.count, weights.contains(where: { $0 > 0 }) {
            policy = .weightedRecords(weights)
        } else {
            policy = .uniformRecords
        }
        self.init(elements: elements, historyLimit: historyLimit, seed: seed,
                  policy: policy, controlledRolls: [])
    }

    init(
        elements: [Element],
        historyLimit: Int = 20,
        seed: UInt64,
        weights: [Int]? = nil,
        controlledRolls: [Double]
    ) {
        let policy: Policy
        if let weights, weights.count == elements.count, weights.contains(where: { $0 > 0 }) {
            policy = .weightedRecords(weights)
        } else {
            policy = .uniformRecords
        }
        self.init(elements: elements, historyLimit: historyLimit, seed: seed,
                  policy: policy, controlledRolls: controlledRolls)
    }

    private init(
        elements: [Element],
        historyLimit: Int,
        seed: UInt64,
        policy: Policy,
        controlledRolls: [Double]
    ) {
        self.elements = elements
        self.historySize = max(0, min(historyLimit, elements.count - 1))
        self.generator = SplitMix64(seed: seed)
        self.policy = policy
        self.controlledRolls = controlledRolls
    }

    public mutating func next() -> Element? {
        guard !elements.isEmpty else { return nil }

        let recent = Set(history)
        let eligible = elements.indices.filter { !recent.contains($0) }
        guard let index = pickIndex(from: eligible) else { return nil }

        history.append(index)
        while history.count > historySize { history.removeFirst() }
        return elements[index]
    }

    private mutating func pickIndex(from eligible: [Int]) -> Int? {
        guard !eligible.isEmpty else { return nil }

        switch policy {
        case .uniformRecords:
            return eligible[pickUniformOffset(count: eligible.count)]

        case let .weightedRecords(weights):
            let positive = eligible.filter { weights[$0] > 0 }
            guard !positive.isEmpty else {
                // Positive-weight records can all be recent. The remaining eligible records
                // then recover uniformly so a nonempty corpus always makes progress.
                return eligible[pickUniformOffset(count: eligible.count)]
            }

            // Scaling avoids integer-overflow accumulation; relative weights are represented
            // to Double precision.
            let largest = positive.map { weights[$0] }.max() ?? 1
            let scaledWeights = positive.map { Double(weights[$0]) / Double(largest) }
            let total = scaledWeights.reduce(0, +)
            let target = nextUnitRoll() * total
            var cumulative = 0.0
            for (offset, weight) in scaledWeights.enumerated() {
                cumulative += weight
                if target < cumulative { return positive[offset] }
            }
            return positive.last

        case let .equalSources(sources):
            var sourceOrder: [String] = []
            var indicesBySource: [String: [Int]] = [:]
            for index in eligible {
                let source = sources[index]
                if indicesBySource[source] == nil { sourceOrder.append(source) }
                indicesBySource[source, default: []].append(index)
            }

            let source = sourceOrder[pickUniformOffset(count: sourceOrder.count)]
            guard let sourceIndices = indicesBySource[source] else { return nil }
            return sourceIndices[pickUniformOffset(count: sourceIndices.count)]
        }
    }

    private mutating func pickUniformOffset(count: Int) -> Int {
        guard count > 1 else { return 0 }
        if let roll = nextControlledRoll() {
            return min(Int(roll * Double(count)), count - 1)
        }
        return Int.random(in: 0 ..< count, using: &generator)
    }

    private mutating func nextUnitRoll() -> Double {
        if let roll = nextControlledRoll() { return roll }

        // The upper 53 bits fill a Double's significand and produce a value in 0..<1.
        return Double(generator.next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    private mutating func nextControlledRoll() -> Double? {
        if controlledRollIndex < controlledRolls.count {
            let roll = controlledRolls[controlledRollIndex]
            controlledRollIndex += 1
            precondition(roll >= 0 && roll < 1, "controlled roll must be in 0..<1")
            return roll
        }
        return nil
    }
}

public extension NoRepeatSelector where Element == Fortune {
    /// - Parameter weightByFile: when true, select an eligible source uniformly and then an
    ///   eligible record from that source uniformly. The default samples all eligible records
    ///   uniformly, regardless of source.
    init(database: FortuneDatabase, historyLimit: Int = 20, seed: UInt64, weightByFile: Bool) {
        let policy: Policy = weightByFile
            ? .equalSources(database.fortunes.map(\.source))
            : .uniformRecords
        self.init(elements: database.fortunes, historyLimit: historyLimit, seed: seed,
                  policy: policy, controlledRolls: [])
    }

    internal init(
        database: FortuneDatabase,
        historyLimit: Int = 20,
        seed: UInt64,
        weightByFile: Bool,
        controlledRolls: [Double]
    ) {
        let policy: Policy = weightByFile
            ? .equalSources(database.fortunes.map(\.source))
            : .uniformRecords
        self.init(elements: database.fortunes, historyLimit: historyLimit, seed: seed,
                  policy: policy, controlledRolls: controlledRolls)
    }
}
