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
    }

    @Test func readsAFullConfigFile() {
        let result = load("""
        {"rotationSeconds": 20, "wrapWidth": 60, "cowfiles": ["tux"], "randomCow": false,
         "face": "tired", "balloonStyle": "think", "fontName": "Monaco", "fontSize": 18,
         "foreground": "#FFB000", "background": "#101010", "transition": "none",
         "reposition": false, "adaptiveWrap": false, "maxFortuneLines": 30,
         "weightByFile": true}
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

    @Test func unknownKeysAreIgnoredSilently() {
        let result = load("{\"wrapWidth\": 50, \"somethingElse\": true}")
        #expect(result.configuration.wrapWidth == 50)
    }

    @Test func missingFileYieldsDefaultsAndAWarning() {
        let result = Configuration.load(
            contentsOf: URL(fileURLWithPath: "/nonexistent/config.json")
        )
        #expect(result.configuration == Configuration())
        #expect(!result.warnings.isEmpty)
    }

    // MARK: Clamping

    @Test(arguments: [(0.0, 1.0), (-5.0, 1.0), (0.001, 1.0), (45.0, 45.0), (1e9, 86_400.0)])
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

    // MARK: Layering

    /// Resolution order is defaults -> ScreenSaverDefaults -> file, and **the file wins**.
    @Test func fileWinsOverScreenSaverDefaults() {
        let fromDefaults: [String: Any] = ["wrapWidth": 30, "fontName": "Monaco"]
        let fromFile: [String: Any] = ["wrapWidth": 70]
        let merged = fromDefaults.merging(fromFile) { _, file in file }

        let result = Configuration.load(object: merged)
        #expect(result.configuration.wrapWidth == 70, "the file must win")
        #expect(result.configuration.fontName == "Monaco", "unset keys fall through")
    }

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
        configuration.foreground = "#FFB000"
        configuration.background = "#101010"
        configuration.theme = "amber"
        configuration.transition = "none"
        configuration.reposition = false
        configuration.adaptiveWrap = false
        configuration.maxFortuneLines = 30
        configuration.weightByFile = true

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
        // If a field is added without adding its key, ScreenSaverDefaults silently stops
        // being able to set it.
        #expect(Configuration.knownKeys.count == 16)
        #expect(Set(Configuration.knownKeys).count == Configuration.knownKeys.count)
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
}
