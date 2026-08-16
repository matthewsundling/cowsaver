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

/// Random selection that will not repeat anything in its recent history.
///
/// A short history avoids immediate repeats without shuffling the whole corpus.
public struct NoRepeatSelector<Element> {
    private let elements: [Element]
    /// Cumulative weights for weighted sampling; empty means uniform.
    private let cumulativeWeights: [Int]
    private let totalWeight: Int
    private var history: [Int] = []
    private let historySize: Int
    private var generator: SplitMix64

    public var isEmpty: Bool { elements.isEmpty }
    public var count: Int { elements.count }

    /// - Parameters:
    ///   - historyLimit: how many recent picks to exclude. Clamped to `count - 1`, so a
    ///     small corpus still makes progress instead of deadlocking.
    ///   - weights: per-element weights. `nil` selects uniformly.
    public init(
        elements: [Element],
        historyLimit: Int = 20,
        seed: UInt64,
        weights: [Int]? = nil
    ) {
        self.elements = elements
        self.historySize = max(0, min(historyLimit, elements.count - 1))
        self.generator = SplitMix64(seed: seed)

        if let weights, weights.count == elements.count, weights.contains(where: { $0 > 0 }) {
            var running = 0
            self.cumulativeWeights = weights.map { weight in
                running += max(0, weight)
                return running
            }
            self.totalWeight = running
        } else {
            self.cumulativeWeights = []
            self.totalWeight = 0
        }
    }

    public mutating func next() -> Element? {
        guard !elements.isEmpty else { return nil }
        if elements.count == 1 { return elements[0] }

        // Bound random retries, then scan for an available element so lopsided weights cannot
        // leave selection looping indefinitely.
        var index = pickIndex()
        var attempts = 0
        while history.contains(index), attempts < 32 {
            index = pickIndex()
            attempts += 1
        }
        if history.contains(index),
           let fallback = (0 ..< elements.count).first(where: { !history.contains($0) }) {
            index = fallback
        }

        history.append(index)
        while history.count > historySize { history.removeFirst() }
        return elements[index]
    }

    private mutating func pickIndex() -> Int {
        guard !cumulativeWeights.isEmpty, totalWeight > 0 else {
            return Int.random(in: 0 ..< elements.count, using: &generator)
        }
        let roll = Int.random(in: 0 ..< totalWeight, using: &generator)
        // Weight arrays here are small (one entry per fortune file); a scan is fine.
        return cumulativeWeights.firstIndex { roll < $0 } ?? elements.count - 1
    }
}

public extension NoRepeatSelector where Element == Fortune {
    /// - Parameter weightByFile: use fortune's size-proportional file weighting. The default
    ///   samples uniformly across individual records.
    init(database: FortuneDatabase, historyLimit: Int = 20, seed: UInt64, weightByFile: Bool) {
        let weights: [Int]? = weightByFile
            ? database.fortunes.map { database.weights[$0.source] ?? 1 }
            : nil
        self.init(elements: database.fortunes, historyLimit: historyLimit,
                  seed: seed, weights: weights)
    }
}
