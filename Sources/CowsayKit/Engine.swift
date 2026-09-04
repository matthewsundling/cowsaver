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
        /// One authoritative, human-readable, content-safe sequence for front-end
        /// logging: `notes` followed by at most 50 resource-specific details drawn from
        /// `cowfilesRejected` and personal fortune loader recovery/limit events, then one
        /// summary line if more details existed than the 50 shown. Every engine-creation
        /// call site should log exactly this sequence rather than assembling its own.
        public var messages: [String] = []
    }

    private let configuration: Configuration
    private var fortunePicker: NoRepeatSelector<Fortune>
    private var cowPicker: NoRepeatSelector<Cowfile>
    /// Kept separate from both content selectors so enabling random balloons cannot move the
    /// established seeded cow or fortune sequences.
    private var balloonGenerator: SplitMix64
    /// Kept separate from every existing picker and the balloon stream. A random face must
    /// not move seeded fortune, cow, or balloon choices made by an existing configuration.
    private var faceGenerator: SplitMix64
    /// The configured cow order, used when random cow selection is off.
    private let orderedCows: [Cowfile]
    private var nextOrderedCowIndex = 0
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

        var seenNames: Set<String> = []
        var configuredNames: [String] = []
        for name in configuration.cowfiles {
            if seenNames.insert(name).inserted {
                configuredNames.append(name)
            } else {
                diagnostics.notes.append("duplicate configured cowfile '\(name)' ignored")
            }
        }

        var enabled: [Cowfile]
        if configuredNames.isEmpty {
            // The empty spelling intentionally means every cow the selected library loaded.
            enabled = library.names.compactMap { library.cow(named: $0) }
        } else {
            enabled = configuredNames.compactMap { library.cow(named: $0) }
            let unavailable = configuredNames.filter { library.cow(named: $0) == nil }
            if !unavailable.isEmpty {
                diagnostics.notes.append(
                    "unavailable configured cowfiles: \(unavailable.joined(separator: ", "))"
                )
            }

            if enabled.isEmpty {
                let defaultNames = Configuration().cowfiles
                enabled = defaultNames.compactMap { library.cow(named: $0) }
                if !enabled.isEmpty {
                    let loadedNames = defaultNames.filter { library.cow(named: $0) != nil }
                    diagnostics.notes.append(
                        "no configured cowfiles loaded; using default cowfiles: "
                            + loadedNames.joined(separator: ", ")
                    )
                } else if !library.isEmpty {
                    enabled = library.names.compactMap { library.cow(named: $0) }
                    diagnostics.notes.append(
                        "no configured or default cowfiles loaded; using all "
                            + "\(enabled.count) available cowfiles"
                    )
                }
            }
        }
        if enabled.isEmpty {
            enabled = [BuiltIn.defaultCow]
            diagnostics.usingBuiltInCow = true
            diagnostics.notes.append("no cowfiles found; using the built-in cow")
        }

        self.orderedCows = enabled
        self.cowPicker = NoRepeatSelector(elements: enabled,
                                          historyLimit: min(5, enabled.count - 1),
                                          seed: seed &* 31)
        self.balloonGenerator = SplitMix64(seed: seed ^ 0xD1B5_4A32_D192_ED03)
        self.faceGenerator = SplitMix64(seed: seed ^ 0xA4C5_3E71_9B20_FD46)

        // --- Fortunes -----------------------------------------------------------
        let loaded = FortuneDatabase.load(directories: fortuneDirectories,
                                          options: configuration.fortuneLoadOptions)
        diagnostics.fortuneStatistics = loaded.statistics
        if loaded.statistics.entryLimitReached {
            diagnostics.notes.append(
                "personal fortune loading stopped after examining "
                    + "\(FortuneDatabase.Limits.production.maxExaminedEntries) filesystem "
                    + "entries; some directories were not fully scanned"
            )
        }
        if loaded.statistics.aggregateByteLimitReached {
            diagnostics.notes.append(
                "personal fortune loading reached its "
                    + "\(FortuneDatabase.Limits.production.maxAggregateBytes)-byte limit; "
                    + "later files were not read"
            )
        }
        if loaded.statistics.recordLimitReached {
            diagnostics.notes.append(
                "personal fortune loading stopped after retaining "
                    + "\(FortuneDatabase.Limits.production.maxRetainedRecords) records; "
                    + "later records were not retained"
            )
        }

        var database = loaded
        if database.isEmpty {
            database = .builtIn()
            diagnostics.usingBuiltInFortunes = true
            diagnostics.notes.append("no fortunes found; using the built-in set")
        }
        diagnostics.fortunesLoaded = database.fortunes.count

        // --- Authoritative diagnostic sequence -----------------------------------
        //
        // Resource-specific details (one rejected cowfile or one loader recovery event
        // apiece) are bounded to 50 for logging even though the structured counts above
        // stay complete; ordinary notes are not resource-specific and are never dropped.
        let resourceDetails = library.failures.map { "cowfile \($0.name): \($0.reason)" }
            + loaded.issues
        let detailLimit = 50
        diagnostics.messages = diagnostics.notes + resourceDetails.prefix(detailLimit)
        if resourceDetails.count > detailLimit {
            diagnostics.messages.append(
                "\(resourceDetails.count - detailLimit) additional resource-specific "
                    + "detail(s) omitted"
            )
        }

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
    /// - Parameter preview: ask for `previewBlock` instead of a fortune, for a host preview
    ///   pane too small to show one honestly.
    public func nextBlock(fitting canvas: AdaptiveWrap.Canvas? = nil,
                          preview: Bool = false) -> String {
        if preview { return Self.previewBlock }
        let fortune = fortunePicker.next()?.text ?? BuiltIn.fortunes[0]
        let cow = nextCow()
        // Pick once per generated block. Adaptive wrapping may render several candidates, but
        // every candidate must compare the same balloon rather than spending another choice.
        let balloonMode = nextBalloonMode()
        // The same is true for a face: one choice belongs to the block, rather than to every
        // adaptive-wrap candidate.
        let face = nextFace()
        let block = bestBlock(fortune: fortune, cow: cow, mode: balloonMode, face: face,
                              canvas: canvas)
        return block.isEmpty ? fallbackBlock(face: face) : block
    }

    private func nextCow() -> Cowfile {
        guard !configuration.randomCow else {
            return cowPicker.next() ?? BuiltIn.defaultCow
        }
        guard !orderedCows.isEmpty else { return BuiltIn.defaultCow }

        let cow = orderedCows[nextOrderedCowIndex]
        nextOrderedCowIndex = (nextOrderedCowIndex + 1) % orderedCows.count
        return cow
    }

    private func nextBalloonMode() -> BalloonMode {
        guard configuration.balloonStyle.lowercased() == "random" else {
            return configuration.balloonMode
        }
        return balloonGenerator.next() & 1 == 0 ? .say : .think
    }

    /// Selects independently and with replacement from the default face plus all eight
    /// cowsay modes. Each non-default mode is constructed on its own so Dead and Stoned carry
    /// cowsay's `U ` tongue while every other choice carries the default tongue.
    private func nextFace() -> Face {
        guard configuration.wantsRandomFace else { return configuration.resolvedFace }
        let index = Int.random(in: 0 ... FaceMode.allCases.count, using: &faceGenerator)
        guard index > 0 else { return .default }
        return Face.construct(modes: [FaceMode.allCases[index - 1]])
    }

    /// Compact deterministic content for a host preview pane.
    ///
    /// A pane a few hundred points across cannot render a 60-line fortune at a readable size,
    /// so it is not asked to. Built once from the compiled-in cow rather than the configured
    /// corpus: a preview draws a single frame and never joins the rotation timer, so it must
    /// not spend a pick from the no-repeat selectors or vary with what loaded from disk.
    /// Eight rows by 36 columns, inside the 12 by 40 a preview is budgeted.
    static let previewBlock = String(
        decoding: CowRenderer.render(message: "Cowsaver: a fortune-telling cow.",
                                     cowfile: BuiltIn.defaultCow),
        as: UTF8.self
    )

    /// Render `fortune` in `cow` at whichever candidate wrap width fills `canvas` best.
    private func bestBlock(fortune: String, cow: Cowfile, mode: BalloonMode, face: Face,
                           canvas: AdaptiveWrap.Canvas?) -> String {
        let base = configuration.effectiveWrapWidth

        func render(at columns: Int) -> String {
            let bytes = CowRenderer.render(CowsayRequest(
                message: Message.linesFromStdin(Bytes.from(fortune)),
                cowfile: cow,
                mode: mode,
                face: face,
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
    private func fallbackBlock(face: Face) -> String {
        String(decoding: CowRenderer.render(message: BuiltIn.fortunes[0],
                                            cowfile: BuiltIn.defaultCow,
                                            face: face), as: UTF8.self)
    }
}
