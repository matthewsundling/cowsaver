import Foundation
import Testing
@testable import CowsayKit

@Suite("Adaptive wrap")
struct AdaptiveWrapTests {
    /// A 16:10 laptop screen in Menlo, which is what the defaults produce.
    private let laptop = AdaptiveWrap.Canvas(aspectRatio: 1440.0 / 900.0,
                                             cellAspectRatio: 60.205078125 / 116.40625)

    // MARK: The score

    @Test func aTallBlockScoresWorseThanAWideOneOfTheSameArea() {
        let tall = AdaptiveWrap.score(columns: 40, rows: 90, on: laptop)
        let wide = AdaptiveWrap.score(columns: 120, rows: 30, on: laptop)
        #expect(wide > tall)
    }

    /// The reason adaptive wrapping pays at all: below the animal's own width, extra
    /// columns are free. A block 40 wide and one 68 wide next to a 68-column stegosaurus
    /// are the same width on screen, so the narrower one has simply spent more rows.
    @Test func widthBelowTheAnimalCostsNothing() {
        let cowLimited = AdaptiveWrap.score(columns: 68, rows: 40, on: laptop)
        let narrower = AdaptiveWrap.score(columns: 68, rows: 60, on: laptop)
        #expect(cowLimited > narrower)
    }

    @Test(arguments: [(0, 10), (10, 0), (0, 0)])
    func degenerateSizesScoreZeroRatherThanDividingByZero(columns: Int, rows: Int) {
        #expect(AdaptiveWrap.score(columns: columns, rows: rows, on: laptop) == 0)
    }

    @Test func aDegenerateCanvasScoresZero() {
        let nothing = AdaptiveWrap.Canvas(aspectRatio: 0, cellAspectRatio: 0)
        #expect(AdaptiveWrap.score(columns: 40, rows: 10, on: nothing) == 0)
    }

    // MARK: Candidates

    @Test func theConfiguredWidthIsAlwaysTheFirstCandidate() {
        #expect(AdaptiveWrap.candidates(base: 40).first == 40)
        #expect(AdaptiveWrap.candidates(base: 25).first == 25)
    }

    /// Candidate widths scale with a narrow configured `wrapWidth`.
    @Test func candidatesScaleWithTheConfiguredWidth() {
        #expect(AdaptiveWrap.candidates(base: 40) == [40, 60, 80, 100, 120])
        #expect(AdaptiveWrap.candidates(base: 20) == [20, 30, 40, 50, 60])
    }

    @Test func candidatesAreBoundedAndDeduplicated() {
        let wide = AdaptiveWrap.candidates(base: 400)
        #expect(wide.allSatisfy { $0 <= 500 })
        #expect(Set(wide).count == wide.count)

        let degenerate = AdaptiveWrap.candidates(base: 1)
        #expect(degenerate.allSatisfy { $0 >= 2 })
        #expect(!degenerate.isEmpty)
    }

    // MARK: Grid measurement

    @Test func gridSizeTakesTheWidestLine() {
        let (columns, rows) = AdaptiveWrap.gridSize(of: "ab\nabcd\nabc")
        #expect(columns == 4)
        #expect(rows == 3)
    }

    @Test func aTrailingNewlineIsNotAnExtraRow() {
        #expect(AdaptiveWrap.gridSize(of: "one\ntwo\n").rows == 2)
    }

    // MARK: End to end, through the engine

    private func engine(_ configure: (inout Configuration) -> Void = { _ in }) -> CowsaverEngine {
        var configuration = Configuration()
        configuration.randomCow = false
        configuration.cowfiles = ["stegosaurus"]
        configure(&configuration)
        let resources = GoldenTests.repositoryRoot.appendingPathComponent("Resources")
        return CowsaverEngine(
            configuration: configuration,
            cowDirectories: [resources.appendingPathComponent("cows")],
            fortuneDirectories: [resources.appendingPathComponent("fortune-curated")],
            seed: 7
        )
    }

    /// Without a canvas, the CLI and golden tests use exactly the configured wrap width.
    @Test func noCanvasMeansNoAdaptation() {
        let plain = engine()
        for _ in 0 ..< 40 {
            #expect(AdaptiveWrap.gridSize(of: plain.nextBlock()).columns <= 68,
                    "stegosaurus is 68 columns; nothing should be wider at -W 40")
        }
    }

    @Test func turningItOffLeavesTheWidthAlone() {
        let fixed = engine { $0.adaptiveWrap = false }
        for _ in 0 ..< 40 {
            let block = fixed.nextBlock(fitting: laptop)
            #expect(AdaptiveWrap.gridSize(of: block).columns <= 68)
        }
    }

    /// Given a canvas, a long fortune can select a width that yields a larger fitted size.
    @Test func aTallFortuneIsRewrappedToScoreBetter() {
        var configuration = Configuration()
        configuration.randomCow = false
        configuration.cowfiles = ["stegosaurus"]
        let cow = GoldenTests.library.cow(named: "stegosaurus")
        let long = String(repeating: "word ", count: 400)

        guard let cow = cow else { return }
        func block(at columns: Int) -> String {
            String(decoding: CowRenderer.render(message: long, cowfile: cow,
                                                wrapColumns: columns), as: UTF8.self)
        }
        let narrow = AdaptiveWrap.score(of: block(at: 40), on: laptop)
        let wide = AdaptiveWrap.score(of: block(at: 80), on: laptop)
        #expect(wide > narrow * AdaptiveWrap.widenThreshold,
                "wrapping wider must clear the threshold, or the engine will never take it")
    }

    /// A short fortune must render byte-identically with and without a canvas. Every
    /// candidate width produces the same balloon, the scores tie, and the narrowest width
    /// remains selected.
    @Test func shortFortunesAreUnchangedByAdaptation() throws {
        let cow = try #require(GoldenTests.library.cow(named: "stegosaurus"))
        let short = "The quick brown fox."
        let fixed = String(decoding: CowRenderer.render(message: short, cowfile: cow,
                                                        wrapColumns: 40), as: UTF8.self)
        for width in AdaptiveWrap.candidates(base: 40) {
            let candidate = String(decoding: CowRenderer.render(message: short, cowfile: cow,
                                                                wrapColumns: width),
                                   as: UTF8.self)
            #expect(candidate == fixed, "a short message must not care about the wrap width")
        }
    }
}
