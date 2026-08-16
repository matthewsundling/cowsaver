import Foundation

/// Produces the next block of ASCII art to put on screen.
///
/// The app and screensaver share this Foundation-only coordinator.
///
/// `nextBlock()` always returns a renderable block. If configured resources cannot provide
/// a cow or fortune, the engine uses the compiled-in fallback content.
public final class CowsaverEngine {
    public struct Diagnostics: Sendable {
        public var cowfilesLoaded = 0
        public var cowfilesRejected: [String] = []
        public var fortunesLoaded = 0
        public var fortuneStatistics = FortuneDatabase.Statistics()
        public var usingBuiltInCow = false
        public var usingBuiltInFortunes = false
        public var notes: [String] = []
    }

    private let configuration: Configuration
    private var fortunePicker: NoRepeatSelector<Fortune>
    private var cowPicker: NoRepeatSelector<Cowfile>
    private let fixedCow: Cowfile?
    public private(set) var diagnostics: Diagnostics

    /// - Parameter seed: seed the picker per view instance, so a second display does not
    ///   show the same fortune at the same moment.
    public init(
        configuration: Configuration,
        cowDirectories: [URL] = [],
        fortuneDirectories: [URL] = [],
        seed: UInt64 = UInt64.random(in: 0 ..< .max)
    ) {
        self.configuration = configuration
        var diagnostics = Diagnostics()

        // --- Cows ---------------------------------------------------------------
        let library = CowfileLibrary.load(directories: cowDirectories)
        diagnostics.cowfilesLoaded = library.cows.count
        diagnostics.cowfilesRejected = library.failures.map { "\($0.name): \($0.reason)" }

        // Use configured cow names when they resolve; otherwise use every loaded cow.
        var enabled = configuration.cowfiles.compactMap { library.cow(named: $0) }
        if enabled.isEmpty, !library.isEmpty {
            enabled = library.names.compactMap { library.cow(named: $0) }
            if !configuration.cowfiles.isEmpty {
                diagnostics.notes.append(
                    "none of the configured cowfiles loaded; using all \(enabled.count) available"
                )
            }
        }
        if enabled.isEmpty {
            enabled = [BuiltIn.defaultCow]
            diagnostics.usingBuiltInCow = true
            diagnostics.notes.append("no cowfiles found; using the built-in cow")
        }

        self.fixedCow = configuration.randomCow ? nil : enabled.first
        self.cowPicker = NoRepeatSelector(elements: enabled,
                                          historyLimit: min(5, enabled.count - 1),
                                          seed: seed &* 31)

        // --- Fortunes -----------------------------------------------------------
        var database = FortuneDatabase.load(directories: fortuneDirectories,
                                            options: configuration.fortuneLoadOptions)
        diagnostics.fortuneStatistics = database.statistics
        if database.isEmpty {
            database = .builtIn()
            diagnostics.usingBuiltInFortunes = true
            diagnostics.notes.append("no fortunes found; using the built-in set")
        }
        diagnostics.fortunesLoaded = database.fortunes.count

        self.fortunePicker = NoRepeatSelector(database: database, historyLimit: 20,
                                              seed: seed,
                                              weightByFile: configuration.weightByFile)
        self.diagnostics = diagnostics
    }

    /// The next rendered block. Safe to call from any thread that owns this engine.
    ///
    /// - Parameter canvas: the shape of the space the block will be drawn in, if the caller
    ///   knows it. Given one, the wrap width is chosen to fill it — see `AdaptiveWrap`.
    ///   Without one this renders once at the configured width, as used by the CLI and
    ///   compatibility fixtures.
    public func nextBlock(fitting canvas: AdaptiveWrap.Canvas? = nil) -> String {
        let fortune = fortunePicker.next()?.text ?? BuiltIn.fortunes[0]
        let cow = fixedCow ?? cowPicker.next() ?? BuiltIn.defaultCow
        let block = bestBlock(fortune: fortune, cow: cow, canvas: canvas)
        return block.isEmpty ? fallbackBlock() : block
    }

    /// Render `fortune` in `cow` at whichever candidate wrap width fills `canvas` best.
    private func bestBlock(fortune: String, cow: Cowfile,
                           canvas: AdaptiveWrap.Canvas?) -> String {
        let base = configuration.effectiveWrapWidth

        func render(at columns: Int) -> String {
            let bytes = CowRenderer.render(CowsayRequest(
                message: Message.linesFromStdin(Bytes.from(fortune)),
                cowfile: cow,
                mode: configuration.balloonMode,
                face: Face.construct(modes: configuration.faceModes),
                wrapColumns: columns
            ))
            // `String(decoding:as:)` always returns a displayable string. The normal resource
            // path is ASCII-only; other callers may receive replacement characters for bytes
            // that are not valid UTF-8.
            return String(decoding: bytes, as: UTF8.self)
        }

        guard configuration.adaptiveWrap, let canvas else { return render(at: base) }

        var best = render(at: base)
        var bestScore = AdaptiveWrap.score(of: best, on: canvas)
        for width in AdaptiveWrap.candidates(base: base).dropFirst() {
            let candidate = render(at: width)
            let score = AdaptiveWrap.score(of: candidate, on: canvas)
            // Require a visible improvement. Ties keep the narrower width, including short
            // fortunes that render identically at every candidate width.
            guard score > bestScore * AdaptiveWrap.widenThreshold else { continue }
            best = candidate
            bestScore = score
        }
        return best
    }

    /// Render the compiled-in cow and first compiled-in fortune.
    private func fallbackBlock() -> String {
        String(decoding: CowRenderer.render(message: BuiltIn.fortunes[0],
                                            cowfile: BuiltIn.defaultCow), as: UTF8.self)
    }
}
