import Foundation
import Testing
@testable import CowsayKit

@Suite("Configuration")
struct ConfigurationTests {
    private func load(_ json: String) -> Configuration.LoadResult {
        Configuration.load(data: Data(json.utf8))
    }

    @Test func defaultsMatchTheDocumentedConfig() {
        let configuration = Configuration()
        #expect(configuration.rotationSeconds == 45)
        #expect(configuration.wrapWidth == 40)
        #expect(configuration.cowfiles == ["stegosaurus", "default", "tux", "dragon"])
        #expect(configuration.foreground == "#33FF66")   // green phosphor
        #expect(configuration.fontSize == 0)             // auto-fit
        #expect(!configuration.debugFrame)
    }

    @Test func debugFrameLoadsFromJSON() {
        let result = load("{\"debugFrame\": true}")
        #expect(result.configuration.debugFrame)
        #expect(result.warnings.isEmpty)
    }

    @Test func debugFrameWrongTypeKeepsTheDefault() {
        let result = load("{\"debugFrame\": \"yes\"}")
        #expect(!result.configuration.debugFrame)
        #expect(result.warnings.contains { $0.contains("debugFrame") })
    }

    @Test func readsAFullConfigFile() {
        let result = load("""
        {"rotationSeconds": 20, "wrapWidth": 60, "cowfiles": ["tux"], "randomCow": false,
         "face": "tired", "balloonStyle": "think", "fontName": "Monaco", "fontSize": 18,
         "foreground": "#FFB000", "background": "#101010", "transition": "none",
         "reposition": false, "adaptiveWrap": false, "maxFortuneLines": 30,
         "weightByFile": true, "debugFrame": true}
        """)
        let c = result.configuration
        #expect(result.warnings.isEmpty)
        #expect(c.rotationSeconds == 20)
        #expect(c.cowfiles == ["tux"])
        #expect(c.balloonMode == .think)
        #expect(c.faceModes == [.tired])
        #expect(!c.wantsTransition)
        #expect(!c.adaptiveWrap)
        #expect(c.maxFortuneLines == 30)
        #expect(c.weightByFile)
        #expect(c.debugFrame)
    }

    // MARK: Invalid and partial input

    /// Malformed configuration input falls back to defaults and reports a warning.
    @Test(arguments: ["", "not json at all", "{", "[1,2,3]", "null", "{\"unclosed\": "])
    func malformedInputYieldsDefaults(json: String) {
        let result = load(json)
        #expect(result.configuration == Configuration())
        #expect(!result.warnings.isEmpty, "a rejected file must say why")
    }

    /// One invalid key does not prevent valid configuration keys from loading.
    @Test func oneWrongTypeDoesNotDiscardTheOtherKeys() {
        let result = load("""
        {"rotationSeconds": "not a number", "wrapWidth": 60, "fontName": "Monaco"}
        """)
        #expect(result.configuration.rotationSeconds == 45, "falls back to the default")
        #expect(result.configuration.wrapWidth == 60, "the good keys still apply")
        #expect(result.configuration.fontName == "Monaco")
        #expect(result.warnings.contains { $0.contains("rotationSeconds") })
    }

    private func numericValue(_ configuration: Configuration, for key: String) -> Double {
        switch key {
        case "rotationSeconds": configuration.rotationSeconds
        case "wrapWidth": Double(configuration.wrapWidth)
        case "fontSize": configuration.fontSize
        case "sizeVariation": configuration.sizeVariation
        case "maxFortuneLines": Double(configuration.maxFortuneLines)
        default: fatalError("unknown numeric key in test")
        }
    }

    private func booleanValue(_ configuration: Configuration, for key: String) -> Bool {
        switch key {
        case "randomCow": configuration.randomCow
        case "reposition": configuration.reposition
        case "adaptiveWrap": configuration.adaptiveWrap
        case "weightByFile": configuration.weightByFile
        case "debugFrame": configuration.debugFrame
        default: fatalError("unknown Boolean key in test")
        }
    }

    private func warning(_ result: Configuration.LoadResult, for key: String,
                         containing text: String) -> Bool {
        result.warnings.contains { $0.contains(key) && $0.contains(text) }
    }

    @Test func wholeNumberFieldsAcceptIntegralJSONNumbers() {
        for key in ["rotationSeconds", "wrapWidth", "maxFortuneLines"] {
            for value in ["40", "40.0"] {
                let result = load("{\"\(key)\": \(value)}")
                #expect(numericValue(result.configuration, for: key) == 40)
                #expect(result.warnings.isEmpty)
            }
        }
    }

    @Test func wholeNumberFieldBoundariesClampAndWarn() {
        let cases: [(key: String, lower: Double, upper: Double, ordinary: Double)] = [
            ("rotationSeconds", 1, 600, 45),
            ("wrapWidth", 2, 500, 40),
            ("maxFortuneLines", 0, 100, 60),
        ]
        for item in cases {
            for value in [item.lower, item.upper, item.ordinary] {
                let result = load("{\"\(item.key)\": \(value)}")
                #expect(numericValue(result.configuration, for: item.key) == value)
                #expect(result.warnings.isEmpty)
            }
            for (value, expected) in [(item.lower - 1, item.lower), (item.upper + 1, item.upper)] {
                let result = load("{\"\(item.key)\": \(value)}")
                #expect(numericValue(result.configuration, for: item.key) == expected)
                #expect(warning(result, for: item.key, containing: "clamped to \(Int(expected))"))
            }
        }
    }

    @Test func fontSizeFileBoundariesPreserveDecimalsAndClamp() {
        let cases: [(input: Double, expected: Double, warning: Bool)] = [
            (-1, 0, true), (0, 0, false), (1, 6, true), (5.9, 6, true),
            (6, 6, false), (6.1, 6.1, false), (18.5, 18.5, false), (143.9, 143.9, false),
            (144, 144, false), (145, 144, true),
        ]
        for item in cases {
            let result = load("{\"fontSize\": \(item.input)}")
            #expect(result.configuration.fontSize == item.expected)
            #expect(warning(result, for: "fontSize", containing: "clamped") == item.warning)
        }
    }

    @Test func sizeVariationFileBoundariesClampAndWarn() {
        let cases: [(input: Double, expected: Double, warning: Bool)] = [
            (-0.1, 0, true), (0, 0, false), (0.1, 0.1, false), (0.3, 0.3, false),
            (0.9, 0.9, false), (1, 0.9, true),
        ]
        for item in cases {
            let result = load("{\"sizeVariation\": \(item.input)}")
            #expect(result.configuration.sizeVariation == item.expected)
            #expect(warning(result, for: "sizeVariation", containing: "clamped") == item.warning)
        }
    }

    @Test func hugeFiniteNumbersClampForEveryNumericField() {
        let expected: [String: (negative: Double, positive: Double)] = [
            "rotationSeconds": (1, 600), "wrapWidth": (2, 500),
            "fontSize": (0, 144), "sizeVariation": (0, 0.9),
            "maxFortuneLines": (0, 100),
        ]
        for (key, limits) in expected {
            for (value, bounded) in [("-1e300", limits.negative), ("1e300", limits.positive)] {
                let result = load("{\"\(key)\": \(value)}")
                #expect(numericValue(result.configuration, for: key) == bounded)
                #expect(warning(result, for: key, containing: "clamped to"))
            }
        }
    }

    @Test func wholeNumberFractionsUseDefaultsInsteadOfTruncating() {
        let defaults = Configuration()
        for key in ["rotationSeconds", "wrapWidth", "maxFortuneLines"] {
            let result = load("{\"\(key)\": 40.5}")
            #expect(numericValue(result.configuration, for: key) == numericValue(defaults, for: key))
            #expect(warning(result, for: key, containing: "using default"))
        }
    }

    @Test func JSONBooleansAreRejectedForEveryNumericField() {
        let result = load("""
        {"rotationSeconds": true, "wrapWidth": false, "fontSize": true,
         "sizeVariation": false, "maxFortuneLines": true}
        """)
        let defaults = Configuration()
        for key in ["rotationSeconds", "wrapWidth", "fontSize", "sizeVariation", "maxFortuneLines"] {
            #expect(numericValue(result.configuration, for: key) == numericValue(defaults, for: key))
            #expect(warning(result, for: key, containing: "using default"))
        }
    }

    @Test func JSONNumbersAreRejectedForEveryBooleanField() {
        let defaults = Configuration()
        for key in ["randomCow", "reposition", "adaptiveWrap", "weightByFile", "debugFrame"] {
            for value in [0, 1] {
                let result = load("{\"\(key)\": \(value)}")
                #expect(booleanValue(result.configuration, for: key) == booleanValue(defaults, for: key))
                #expect(warning(result, for: key, containing: "using default"))
            }
        }
    }

    @Test func nonFiniteValuesUseDefaultsForEveryNumericField() {
        let defaults = Configuration()
        for key in ["rotationSeconds", "wrapWidth", "fontSize", "sizeVariation", "maxFortuneLines"] {
            for value in [Double.nan, Double.infinity, -Double.infinity] {
                let result = Configuration.load(object: [key: value])
                #expect(numericValue(result.configuration, for: key) == numericValue(defaults, for: key))
                #expect(warning(result, for: key, containing: "using default"))
            }
        }
    }

    @Test func invalidAndClampedFieldsDoNotDiscardValidSiblings() {
        let invalid = load("""
        {"wrapWidth": 40.5, "rotationSeconds": 20, "fontSize": 18.5, "randomCow": false}
        """)
        #expect(invalid.configuration.wrapWidth == 40)
        #expect(invalid.configuration.rotationSeconds == 20)
        #expect(invalid.configuration.fontSize == 18.5)
        #expect(!invalid.configuration.randomCow)
        #expect(warning(invalid, for: "wrapWidth", containing: "using default"))

        let clamped = load("{\"maxFortuneLines\": 1e300, \"wrapWidth\": 60}")
        #expect(clamped.configuration.maxFortuneLines == 100)
        #expect(clamped.configuration.wrapWidth == 60)
        #expect(warning(clamped, for: "maxFortuneLines", containing: "clamped to 100"))
    }

    @Test func directConfigurationsKeepDerivedNumericValuesSafe() {
        var configuration = Configuration()
        configuration.rotationSeconds = .nan
        #expect(configuration.rotationInterval == 45)
        configuration.rotationSeconds = .infinity
        #expect(configuration.rotationInterval == 45)
        configuration.rotationSeconds = -Double.greatestFiniteMagnitude
        #expect(configuration.rotationInterval == 1)

        configuration.wrapWidth = Int.max
        #expect(configuration.effectiveWrapWidth == 500)
        configuration.wrapWidth = Int.min
        #expect(configuration.effectiveWrapWidth == 2)

        configuration.sizeVariation = .nan
        #expect(configuration.effectiveSizeVariation == 0)
        configuration.sizeVariation = .infinity
        #expect(configuration.effectiveSizeVariation == 0)
        configuration.sizeVariation = -Double.greatestFiniteMagnitude
        #expect(configuration.effectiveSizeVariation == 0)

        configuration.fontSize = .nan
        #expect(configuration.effectivePinnedFontSize == 0)
        configuration.fontSize = .infinity
        #expect(configuration.effectivePinnedFontSize == 0)
        configuration.fontSize = -Double.greatestFiniteMagnitude
        #expect(configuration.effectivePinnedFontSize == 0)
        configuration.fontSize = Double.greatestFiniteMagnitude
        #expect(configuration.effectivePinnedFontSize == 144)

        configuration.maxFortuneLines = Int.max
        #expect(configuration.fortuneLoadOptions.maxLines == 100)
        configuration.maxFortuneLines = Int.min
        #expect(configuration.fortuneLoadOptions.maxLines == 0)
    }

    /// A misspelled key used to look exactly like a setting that had no effect (issue #12).
    @Test func anUnknownKeyWarnsAndNamesItself() {
        let result = load("{\"wrapWidth\": 50, \"somethingElse\": true}")
        #expect(result.configuration.wrapWidth == 50, "the keys it does know still load")
        #expect(result.warnings.count == 1)
        #expect(result.warnings.contains { $0.contains("somethingElse") },
                "the warning must name the key: \(result.warnings)")
    }

    /// Sorted, so a log grep and a test see the same order every time.
    @Test func unknownKeysWarnInASettledOrder() {
        let result = load("{\"zebra\": 1, \"aardvark\": 2}")
        #expect(result.warnings.count == 2)
        #expect(result.warnings[0].hasPrefix("aardvark"))
        #expect(result.warnings[1].hasPrefix("zebra"))
    }

    /// The other half of the warning: a file using every key Cowsaver has must stay quiet, or
    /// the warning is noise on a perfectly good config.
    @Test func noKeyTheLoaderKnowsIsReportedAsUnknown() {
        var configuration = Configuration()
        configuration.theme = "amber"   // the one key jsonObject omits while it is unset
        #expect(Set(configuration.jsonObject.keys) == Set(Configuration.knownKeys))

        let result = Configuration.load(object: configuration.jsonObject)
        #expect(result.warnings.isEmpty, "warned about a key it knows: \(result.warnings)")
    }

    @Test func missingFileYieldsDefaultsAndAWarning() {
        let result = Configuration.load(
            contentsOf: URL(fileURLWithPath: "/nonexistent/config.json")
        )
        #expect(result.configuration == Configuration())
        #expect(!result.warnings.isEmpty)
    }

    // MARK: Clamping

    @Test(arguments: [(0.0, 1.0), (-5.0, 1.0), (0.001, 1.0), (45.0, 45.0), (1e9, 600.0)])
    func rotationIntervalIsClamped(input: Double, expected: Double) {
        var configuration = Configuration()
        configuration.rotationSeconds = input
        #expect(configuration.rotationInterval == expected)
    }

    @Test(arguments: [(0, 2), (1, 2), (40, 40), (100_000, 500)])
    func wrapWidthIsClamped(input: Int, expected: Int) {
        var configuration = Configuration()
        configuration.wrapWidth = input
        #expect(configuration.effectiveWrapWidth == expected)
    }

    @Test(arguments: [(-1.0, 0.0), (0.0, 0.0), (0.3, 0.3), (2.0, 0.9)])
    func sizeVariationIsClamped(input: Double, expected: Double) {
        var configuration = Configuration()
        configuration.sizeVariation = input
        #expect(configuration.effectiveSizeVariation == expected)
    }

    @Test func anOutOfRangeSizeVariationClampsWhileLoading() {
        let result = load("{\"sizeVariation\": 2.0}")
        #expect(result.configuration.sizeVariation == 0.9)
        #expect(result.configuration.effectiveSizeVariation == 0.9)
        #expect(warning(result, for: "sizeVariation", containing: "clamped to 0.9"))
    }

    @Test func sizeVariationOfTheWrongTypeKeepsTheDefault() {
        let result = load("{\"sizeVariation\": \"a lot\"}")
        #expect(result.configuration.sizeVariation == 0)
        #expect(result.warnings.contains { $0.contains("sizeVariation") })
    }

    // MARK: Colours and themes

    @Test(arguments: ["#33FF66", "33FF66", "#3F6", "3f6"])
    func parsesHexColours(hex: String) {
        #expect(ThemeColor(hex: hex) != nil)
    }

    @Test(arguments: ["", "#12345", "zzzzzz", "#GGGGGG", "rgb(1,2,3)"])
    func rejectsBadHexColours(hex: String) {
        #expect(ThemeColor(hex: hex) == nil)
    }

    @Test func badColourFallsBackRatherThanFailing() {
        var configuration = Configuration()
        configuration.foreground = "not a colour"
        #expect(configuration.resolvedForeground.green > 0.5, "fell back to green phosphor")
    }

    @Test func namedThemeOverridesRawColours() {
        var configuration = Configuration()
        configuration.foreground = "#FFFFFF"
        configuration.theme = "amber"
        #expect(configuration.resolvedForeground == ThemeColor(hex: "#FFB000"))
    }

    @Test func unknownThemeIsIgnoredWithAWarning() {
        let result = load("{\"theme\": \"chartreuse\", \"foreground\": \"#123456\"}")
        #expect(result.configuration.resolvedForeground == ThemeColor(hex: "#123456"))
        #expect(result.warnings.contains { $0.contains("chartreuse") })
    }

    @Test func allPresetsParse() {
        for preset in ThemePreset.all {
            #expect(ThemeColor(hex: preset.foreground) != nil, "\(preset.name) foreground")
            #expect(ThemeColor(hex: preset.background) != nil, "\(preset.name) background")
        }
    }

    // MARK: Face and balloon spelling

    @Test(arguments: [
        (input: "tired", expected: Set<FaceMode>([.tired])),
        (input: "t", expected: Set<FaceMode>([.tired])),
        (input: "dead,young", expected: Set<FaceMode>([.dead, .young])),
        (input: "default", expected: Set<FaceMode>()),
        (input: "nonsense", expected: Set<FaceMode>()),
    ] as [(input: String, expected: Set<FaceMode>)])
    func parsesFaceSpellings(input: String, expected: Set<FaceMode>) {
        var configuration = Configuration()
        configuration.face = input
        #expect(configuration.faceModes == expected)
    }

    /// `-t` is tired eyes; the thought bubble is `balloonStyle`. The config must not
    /// re-create that conflation.
    @Test func balloonStyleIsSeparateFromTheTiredFace() {
        var configuration = Configuration()
        configuration.face = "tired"
        #expect(configuration.balloonMode == .say, "tired eyes must not imply a thought bubble")
        configuration.balloonStyle = "think"
        #expect(configuration.balloonMode == .think)
    }

    // MARK: The persisted schema

    /// What the Options sheet writes must be exactly what the loader reads back. A key on
    /// one side and not the other is a setting that appears to save and then does nothing.
    @Test func jsonObjectRoundTripsThroughTheLoader() {
        var configuration = Configuration()
        configuration.rotationSeconds = 20
        configuration.wrapWidth = 55
        configuration.cowfiles = ["tux", "dragon"]
        configuration.randomCow = false
        configuration.face = "tired"
        configuration.balloonStyle = "think"
        configuration.fontName = "Monaco"
        configuration.fontSize = 18
        configuration.sizeVariation = 0.4
        configuration.foreground = "#FFB000"
        configuration.background = "#101010"
        configuration.theme = "amber"
        configuration.transition = "none"
        configuration.reposition = false
        configuration.adaptiveWrap = false
        configuration.maxFortuneLines = 30
        configuration.weightByFile = true
        configuration.debugFrame = true

        let result = Configuration.load(object: configuration.jsonObject)
        #expect(result.configuration == configuration)
        #expect(result.warnings.isEmpty, "a file we wrote ourselves must not warn")
    }

    @Test func defaultsRoundTripWithoutWarnings() {
        let result = Configuration.load(object: Configuration().jsonObject)
        #expect(result.configuration == Configuration())
        #expect(result.warnings.isEmpty)
    }

    /// An unset theme means "use my own colours". Writing it as "" would both warn on every
    /// load and make that state impossible to express.
    @Test func anUnsetThemeIsOmittedRatherThanWrittenEmpty() {
        var configuration = Configuration()
        configuration.theme = nil
        configuration.foreground = "#FF00FF"
        #expect(configuration.jsonObject["theme"] == nil)

        let result = Configuration.load(object: configuration.jsonObject)
        #expect(result.configuration.theme == nil)
        #expect(result.configuration.foreground == "#FF00FF")
        #expect(result.warnings.isEmpty)
    }

    @Test func jsonObjectCoversEveryKnownKey() {
        // `theme` is absent by default and covered by its own test above.
        let written = Set(Configuration().jsonObject.keys)
        for key in Configuration.knownKeys where key != "theme" {
            #expect(written.contains(key), "\(key) is never written back")
        }
        for key in written {
            #expect(Configuration.knownKeys.contains(key), "\(key) is written but never read")
        }
    }

    @Test func knownKeysCoverEveryConfigurableField() {
        // A field added without its key would be read from the file and then reported as a
        // key Cowsaver does not know.
        #expect(Configuration.knownKeys.count == 18)
        #expect(Set(Configuration.knownKeys).count == Configuration.knownKeys.count)
    }

    /// A named theme supplies both colours, so the default one has to step aside for a file
    /// that states colours of its own.
    @Test func coloursInTheFileBeatTheDefaultTheme() {
        let result = Configuration.load(object: ["foreground": "#FF0000"])
        #expect(result.configuration.theme == nil)
        #expect(result.configuration.resolvedForeground.red > 0.9)
        #expect(result.configuration.resolvedForeground.green < 0.1)
        #expect(result.warnings.isEmpty, "\(result.warnings)")
    }
}

// MARK: - Engine

@Suite("Engine")
struct EngineTests {
    private var resources: URL { GoldenTests.repositoryRoot.appendingPathComponent("Resources") }

    @Test func rendersFromTheBundledResources() {
        let engine = CowsaverEngine(
            configuration: Configuration(),
            cowDirectories: [resources.appendingPathComponent("cows")],
            fortuneDirectories: [resources.appendingPathComponent("fortune-curated")],
            seed: 1
        )
        #expect(engine.diagnostics.cowfilesLoaded == 47)
        #expect(engine.diagnostics.fortunesLoaded >= 250)
        #expect(!engine.diagnostics.usingBuiltInCow)
        #expect(!engine.diagnostics.usingBuiltInFortunes)

        let block = engine.nextBlock()
        #expect(block.contains("_"), "a balloon should have a top border")
        #expect(block.split(separator: "\n").count > 3)
    }

    /// The fail-safe for no `Resources/` at all, which is what a partial install or a
    /// sandbox denial looks like.
    @Test func rendersWithNoResourcesAtAll() {
        let engine = CowsaverEngine(
            configuration: Configuration(),
            cowDirectories: [URL(fileURLWithPath: "/nonexistent/cows")],
            fortuneDirectories: [URL(fileURLWithPath: "/nonexistent/fortunes")],
            seed: 1
        )
        #expect(engine.diagnostics.usingBuiltInCow)
        #expect(engine.diagnostics.usingBuiltInFortunes)
        #expect(!engine.diagnostics.notes.isEmpty, "degradation must be reported")

        let block = engine.nextBlock()
        #expect(!block.isEmpty)
        #expect(block.contains("^__^"), "the built-in cow should be recognisable")
    }

    /// A typo in `cowfiles` should cost you your preference, not your screensaver.
    @Test func unknownCowfileNamesFallBackToEverythingAvailable() {
        var configuration = Configuration()
        configuration.cowfiles = ["definitely-not-a-cow", "nor-this"]
        let engine = CowsaverEngine(
            configuration: configuration,
            cowDirectories: [resources.appendingPathComponent("cows")],
            fortuneDirectories: [resources.appendingPathComponent("fortune-curated")],
            seed: 2
        )
        #expect(!engine.diagnostics.usingBuiltInCow)
        #expect(engine.diagnostics.notes.contains { $0.contains("configured cowfiles") })
        #expect(!engine.nextBlock().isEmpty)
    }

    @Test func emptyCowfileListStillRenders() {
        var configuration = Configuration()
        configuration.cowfiles = []
        let engine = CowsaverEngine(
            configuration: configuration,
            cowDirectories: [resources.appendingPathComponent("cows")],
            fortuneDirectories: [resources.appendingPathComponent("fortune-curated")],
            seed: 3
        )
        #expect(!engine.nextBlock().isEmpty)
    }

    @Test func randomCowFalsePinsASingleCow() {
        var configuration = Configuration()
        configuration.randomCow = false
        configuration.cowfiles = ["stegosaurus"]
        let engine = CowsaverEngine(
            configuration: configuration,
            cowDirectories: [resources.appendingPathComponent("cows")],
            fortuneDirectories: [resources.appendingPathComponent("fortunes")],
            seed: 4
        )
        let blocks = (0 ..< 5).map { _ in engine.nextBlock() }
        // Same cow every time; only the balloon above it changes.
        let tails = blocks.map { $0.split(separator: "\n").suffix(6).joined(separator: "\n") }
        #expect(Set(tails).count == 1)
    }

    /// Two displays must not show the same fortune at the same moment.
    @Test func differentSeedsProduceDifferentSequences() {
        func blocks(seed: UInt64) -> [String] {
            let engine = CowsaverEngine(
                configuration: Configuration(),
                cowDirectories: [resources.appendingPathComponent("cows")],
                fortuneDirectories: [resources.appendingPathComponent("fortune-curated")],
                seed: seed
            )
            return (0 ..< 10).map { _ in engine.nextBlock() }
        }
        #expect(blocks(seed: 100) != blocks(seed: 200))
    }

    @Test func neverReturnsAnEmptyBlock() {
        let engine = CowsaverEngine(configuration: Configuration(), seed: 5)
        for _ in 0 ..< 50 { #expect(!engine.nextBlock().isEmpty) }
    }

    /// A preview pane gets content sized for it, and the same content every time.
    ///
    /// The budget is what a System Settings thumbnail can show at a readable size; identical
    /// blocks prove the preview never spends a pick from the rotation it does not join.
    @Test func previewContentFitsTheThumbnailBudget() {
        let engine = CowsaverEngine(
            configuration: Configuration(),
            cowDirectories: [resources.appendingPathComponent("cows")],
            fortuneDirectories: [resources.appendingPathComponent("fortune-curated")],
            seed: 6
        )
        let block = engine.nextBlock(preview: true)
        let grid = AdaptiveWrap.gridSize(of: block)
        #expect(grid.rows <= 12, "\(grid.rows) rows")
        #expect(grid.columns <= 40, "\(grid.columns) columns")
        #expect(block.contains("^__^"), "the classic cow should be recognisable")
        #expect(engine.nextBlock(preview: true) == block, "preview content must not vary")
        #expect(engine.nextBlock(preview: true) == block)
    }
}
