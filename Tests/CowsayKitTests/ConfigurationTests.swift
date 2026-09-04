import Foundation
import Testing
@testable import CowsayKit

@Suite("Configuration")
struct ConfigurationTests {
    private func load(_ json: String) -> Configuration.LoadResult {
        Configuration.load(data: Data(json.utf8))
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
         "face": "tired", "eyes": "ABCD", "tongue": "Q ", "balloonStyle": "think",
         "fontName": "Monaco", "fontSize": 18,
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
        #expect(c.eyes == "ABCD")
        #expect(c.tongue == "Q ")
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
        configuration.theme = "amber"
        configuration.eyes = "oo"
        configuration.tongue = "  "
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

    @Test func configurationFileStatesAreDistinctAndComparable() {
        let readable = ConfigurationFileState.readable(Data("{}".utf8))
        #expect(ConfigurationFileState.missing != .unreadable)
        #expect(ConfigurationFileState.missing != .oversized)
        #expect(ConfigurationFileState.unreadable != .oversized)
        #expect(readable != .missing)
        #expect(readable == .readable(Data("{}".utf8)))
        #expect(readable != .readable(Data("{\"wrapWidth\": 60}".utf8)))
    }

    @Test func aConfigurationExactlyAtTheByteLimitIsAccepted() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowsaver-config-limit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = "{\"wrapWidth\":60}"
        let data = Data((json + String(repeating: " ", count: Configuration.maximumFileBytes - json.utf8.count)).utf8)
        #expect(data.count == Configuration.maximumFileBytes)
        try data.write(to: url)

        let result = Configuration.load(contentsOf: url)
        #expect(result.configuration.wrapWidth == 60)
        #expect(result.warnings.isEmpty)
    }

    @Test func aConfigurationOneByteOverTheLimitIsRejectedBeforeParsing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowsaver-config-oversized-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x7B, count: Configuration.maximumFileBytes + 1).write(to: url)

        let result = Configuration.load(contentsOf: url)
        #expect(result.configuration == Configuration())
        #expect(result.warnings == [
            "config file at \(url.path) exceeds the 65536-byte limit; using defaults"
        ])
    }

    @Test func boundedConfigurationReaderAcceptsShortChunksThroughCleanEOF() {
        let expected = Data("{\"wrapWidth\":60}".utf8)
        var offset = 0
        let state = Configuration.fileState(readingChunks: { requested in
            guard offset < expected.count else { return nil }
            let end = min(offset + min(3, requested), expected.count)
            defer { offset = end }
            return expected[offset ..< end]
        })
        #expect(state == .readable(expected))
    }

    @Test func boundedConfigurationReaderReportsReadFailureInsteadOfUsingAPartialPrefix() {
        var calls = 0
        let state = Configuration.fileState(readingChunks: { _ in
            calls += 1
            if calls == 1 { return Data("{".utf8) }
            throw CocoaError(.fileReadUnknown)
        })
        #expect(state == .unreadable)
    }

    @Test func boundedConfigurationReaderRetainsOnlyTheOverflowSentinel() {
        var bytesSupplied = 0
        let state = Configuration.fileState(readingChunks: { requested in
            let chunk = Data(repeating: 0x20, count: requested)
            bytesSupplied += chunk.count
            return chunk
        })
        #expect(state == .oversized)
        #expect(bytesSupplied == Configuration.maximumFileBytes + 1)
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

    @Test func sizeVariationOfTheWrongTypeKeepsTheDefault() {
        let result = load("{\"sizeVariation\": \"a lot\"}")
        #expect(result.configuration.sizeVariation == 0)
        #expect(result.warnings.contains { $0.contains("sizeVariation") })
    }

    // MARK: Colors and themes

    @Test(arguments: ["#33FF66", "33FF66", "#3F6", "3f6"])
    func parsesHexColors(hex: String) {
        #expect(ThemeColor(hex: hex) != nil)
    }

    @Test(arguments: ["", "#12", "#1234", "#12345", "#1234567", "zzzzzz", "#GGGGGG",
                      "rgb(1,2,3)", " #123", "#123 ", "##123"])
    func rejectsBadHexColors(hex: String) {
        #expect(ThemeColor(hex: hex) == nil)
    }

    @Test func colorFieldsPreserveEveryDocumentedSpelling() {
        for key in ["foreground", "background"] {
            for spelling in ["#AbC", "aBc", "#12aB9F", "12Ab9f"] {
                let result = load("{\"\(key)\": \"\(spelling)\"}")
                let stored = key == "foreground"
                    ? result.configuration.foreground : result.configuration.background
                #expect(stored == spelling)
                #expect(result.warnings.isEmpty)
            }
        }
    }

    @Test func invalidColorsUseTheirStoredFieldDefaults() {
        let cases: [(key: String, value: String)] = [
            ("foreground", "#12"), ("foreground", "#GGG"),
            ("background", "rgb(0,0,0)"), ("background", ""),
        ]
        for item in cases {
            let result = load("{\"\(item.key)\": \"\(item.value)\"}")
            let expected = item.key == "foreground" ? "#33FF66" : "#000000"
            let stored = item.key == "foreground"
                ? result.configuration.foreground : result.configuration.background
            #expect(stored == expected)
            #expect(warning(result, for: item.key, containing: "using \(expected)"))
        }
    }

    @Test func nullAndWrongTypeColorsUseDefaultsIndependently() {
        let result = load("""
        {"foreground": null, "background": 123, "fontName": "Monaco"}
        """)
        #expect(result.configuration.foreground == "#33FF66")
        #expect(result.configuration.background == "#000000")
        #expect(result.configuration.fontName == "Monaco")
        #expect(warning(result, for: "foreground", containing: "using #33FF66"))
        #expect(warning(result, for: "background", containing: "using #000000"))
    }

    @Test func invalidForegroundDoesNotDiscardAValidBackground() {
        let result = load("""
        {"foreground": "nope", "background": "#123456"}
        """)
        #expect(result.configuration.theme == nil)
        #expect(result.configuration.foreground == "#33FF66")
        #expect(result.configuration.background == "#123456")
        #expect(result.warnings.count == 1)
    }

    @Test func namedThemeOverridesRawColors() {
        var configuration = Configuration()
        configuration.foreground = "#FFFFFF"
        configuration.theme = "amber"
        #expect(configuration.resolvedForeground == ThemeColor(hex: "#FFB000"))
    }

    @Test func everyThemePresetNormalizesToItsCanonicalName() {
        for preset in ThemePreset.all {
            let mixedCase = preset.name.uppercased()
            let result = load("{\"theme\": \"\(mixedCase)\"}")
            #expect(result.configuration.theme == preset.name)
            #expect(result.configuration.jsonObject["theme"] as? String == preset.name)
            #expect(result.warnings.isEmpty)
        }
    }

    @Test func presentInvalidThemeUsesGreenPhosphorInsteadOfCustomColors() {
        let result = load("{\"theme\": \"chartreuse\", \"foreground\": \"#123456\"}")
        #expect(result.configuration.theme == "green-phosphor")
        #expect(result.configuration.foreground == "#123456", "raw fields still persist")
        #expect(result.configuration.resolvedForeground == ThemeColor(hex: "#33FF66"))
        #expect(warning(result, for: "theme", containing: "using green-phosphor"))
    }

    @Test func emptyNullAndWrongTypeThemesUseGreenPhosphor() {
        for value in ["\"\"", "null", "false", "[]"] {
            let result = load("{\"theme\": \(value), \"foreground\": \"#123456\"}")
            #expect(result.configuration.theme == "green-phosphor")
            #expect(result.configuration.resolvedForeground == ThemeColor(hex: "#33FF66"))
            #expect(warning(result, for: "theme", containing: "using green-phosphor"))
        }
    }

    @Test func omittedThemeWithoutColorsUsesTheDefaultPresetQuietly() {
        let result = load("{\"fontName\": \"Monaco\"}")
        #expect(result.configuration.theme == "green-phosphor")
        #expect(result.warnings.isEmpty)
    }

    @Test func omittedThemeWithCustomColorsKeepsValidValues() {
        let result = load("{\"foreground\": \"ABC\", \"background\": \"123456\"}")
        #expect(result.configuration.theme == nil)
        #expect(result.configuration.foreground == "ABC")
        #expect(result.configuration.background == "123456")
        #expect(result.warnings.isEmpty)
        #expect(result.configuration.jsonObject["theme"] == nil)
    }

    @Test func namedThemeWinsWhileRawFieldsStillValidateAndDefault() {
        let result = load("""
        {"theme": "AMBER", "foreground": "nope", "background": "#123456"}
        """)
        #expect(result.configuration.theme == "amber")
        #expect(result.configuration.foreground == "#33FF66")
        #expect(result.configuration.background == "#123456")
        #expect(result.configuration.resolvedForeground == ThemeColor(hex: "#FFB000"))
        #expect(result.configuration.resolvedBackground == ThemeColor(hex: "#000000"))
        #expect(warning(result, for: "foreground", containing: "using #33FF66"))
    }

    @Test func allPresetsParse() {
        for preset in ThemePreset.all {
            #expect(ThemeColor(hex: preset.foreground) != nil, "\(preset.name) foreground")
            #expect(ThemeColor(hex: preset.background) != nil, "\(preset.name) background")
        }
    }

    // MARK: Categorical strings, face, and font

    @Test func balloonAndTransitionAcceptEveryOption() {
        for (key, values) in [("balloonStyle", ["say", "think", "random"]),
                              ("transition", ["fade", "none"])] {
            for value in values {
                let result = load("{\"\(key)\": \"\(value)\"}")
                #expect(result.configuration.jsonObject[key] as? String == value)
                #expect(result.warnings.isEmpty)
            }
        }
    }

    @Test func balloonAndTransitionNormalizeMixedCaseWhenSerialized() {
        let result = load("{\"balloonStyle\": \"ThInK\", \"transition\": \"NoNe\"}")
        #expect(result.configuration.balloonStyle == "think")
        #expect(result.configuration.transition == "none")
        #expect(result.configuration.jsonObject["balloonStyle"] as? String == "think")
        #expect(result.configuration.jsonObject["transition"] as? String == "none")
        #expect(result.warnings.isEmpty)
    }

    @Test func invalidBalloonAndTransitionValuesWarnAndUseDefaults() {
        for json in [
            "{\"balloonStyle\": \"shout\", \"transition\": \"slide\"}",
            "{\"balloonStyle\": \"\", \"transition\": \"\"}",
            "{\"balloonStyle\": 1, \"transition\": null}",
        ] {
            let result = load(json)
            #expect(result.configuration.balloonStyle == "say")
            #expect(result.configuration.transition == "fade")
            #expect(warning(result, for: "balloonStyle", containing: "using say"))
            #expect(warning(result, for: "transition", containing: "using fade"))
        }
    }

    @Test func omittedBalloonAndTransitionUseDefaultsQuietly() {
        let result = load("{}")
        #expect(result.configuration.balloonStyle == "say")
        #expect(result.configuration.transition == "fade")
        #expect(result.warnings.isEmpty)
    }

    @Test func directUnknownBalloonAndTransitionValuesRetainSafeDerivedBehavior() {
        var configuration = Configuration()
        configuration.balloonStyle = "shout"
        configuration.transition = "slide"
        #expect(configuration.balloonMode == .say)
        #expect(configuration.wantsTransition)
    }

    @Test func everyCanonicalFaceModeAndAliasLoadsCaseInsensitively() {
        for mode in FaceMode.allCases {
            for spelling in [mode.rawValue, String(mode.flag)] {
                let result = load("{\"face\": \"\(spelling.uppercased())\"}")
                #expect(result.configuration.face == spelling)
                #expect(result.configuration.faceModes == [mode])
                #expect(result.warnings.isEmpty)
            }
        }
    }

    @Test func faceAcceptsCommaAndWhitespaceSeparatorsAndSerializesStably() {
        let result = load("{\"face\": \"BoRg, D\\tYOUNG  s\"}")
        #expect(result.configuration.face == "borg, d, young, s")
        #expect(result.configuration.faceModes == [.borg, .dead, .young, .stoned])
        #expect(result.configuration.jsonObject["face"] as? String == "borg, d, young, s")
        #expect(result.warnings.isEmpty)
    }

    @Test func faceRejectsBadTokensWithoutDiscardingRecognizedSiblings() {
        let result = load("{\"face\": \"dead, Mystery y NOPE\"}")
        #expect(result.configuration.face == "dead, y")
        #expect(result.configuration.faceModes == [.dead, .young])
        #expect(warning(result, for: "face", containing: "'Mystery'"))
        #expect(warning(result, for: "face", containing: "'NOPE'"))
        #expect(!result.warnings.contains { $0.contains("using default") })
    }

    @Test func allInvalidOrEmptyFaceUsesDefaultAndSaysSo() {
        for value in ["mystery nope", ""] {
            let result = load("{\"face\": \"\(value)\"}")
            #expect(result.configuration.face == "default")
            #expect(result.configuration.faceModes.isEmpty)
            #expect(warning(result, for: "face", containing: "using default"))
        }
    }

    @Test func defaultFaceAloneOrAlongsideModesHasNoModeOfItsOwn() {
        let alone = load("{\"face\": \"DeFaUlT\"}")
        #expect(alone.configuration.face == "default")
        #expect(alone.configuration.faceModes.isEmpty)
        #expect(alone.warnings.isEmpty)

        let alongside = load("{\"face\": \"default, DEAD default y\"}")
        #expect(alongside.configuration.face == "dead, y")
        #expect(alongside.configuration.faceModes == [.dead, .young])
        #expect(alongside.warnings.isEmpty)
    }

    @Test func wrongTypeFaceUsesDefaultWithAWarning() {
        let result = load("{\"face\": [\"dead\"]}")
        #expect(result.configuration.face == "default")
        #expect(warning(result, for: "face", containing: "using default"))
    }

    @Test func optionalEyesAndTonguePreserveEveryStringExactly() {
        for (key, value) in [
            ("eyes", ""), ("eyes", "  "), ("eyes", "é🙂long"),
            ("tongue", ""), ("tongue", " \t"), ("tongue", "牛舌long"),
        ] {
            let result = Configuration.load(object: [key: value])
            #expect(result.warnings.isEmpty)
            #expect(result.configuration.jsonObject[key] as? String == value)
        }
    }

    @Test func missingEyesAndTongueStayUnsetAndAreOmitted() {
        let result = load("{}")
        #expect(result.configuration.eyes == nil)
        #expect(result.configuration.tongue == nil)
        #expect(result.configuration.jsonObject["eyes"] == nil)
        #expect(result.configuration.jsonObject["tongue"] == nil)
    }

    @Test func wrongTypeEyesAndTongueWarnAndRecoverToUnset() {
        for key in ["eyes", "tongue"] {
            for value: Any in [NSNull(), 12, false, ["oo"]] {
                let result = Configuration.load(object: [key: value])
                #expect(result.configuration.jsonObject[key] == nil)
                #expect(warning(result, for: key, containing: "leaving unset"))
            }
        }
    }

    @Test func resolvedFaceUsesOnlyTheFirstTwoUTF8Bytes() {
        var configuration = Configuration()
        configuration.eyes = "éyes"
        configuration.tongue = "🙂"
        #expect(configuration.resolvedFace.eyes == Array("é".utf8))
        #expect(configuration.resolvedFace.tongue == Array("🙂".utf8.prefix(2)))
    }

    @Test func fileFaceModesKeepCowsayPrecedenceOverCustomValues() {
        var configuration = Configuration()
        configuration.eyes = "AB"
        configuration.tongue = "QQ"
        configuration.face = "dead, young"
        #expect(configuration.resolvedFace.eyes == Bytes.from(".."),
                "young overrides custom eyes after dead")
        #expect(configuration.resolvedFace.tongue == Bytes.from("U "),
                "dead overrides the custom tongue")
    }

    @Test func normalizedFaceModesKeepCowsayPrecedence() {
        let result = load("""
        {"face": "young wired tired stoned paranoid greedy dead borg"}
        """)
        let face = Face.construct(modes: result.configuration.faceModes)
        #expect(Bytes.describe(face.eyes) == "..", "young remains the final eye override")
        #expect(Bytes.describe(face.tongue) == "U ", "dead and stoned still set the tongue")
    }

    @Test func fontNameLoadsAndTrimsSurroundingWhitespace() {
        let ordinary = load("{\"fontName\": \"Monaco\"}")
        #expect(ordinary.configuration.fontName == "Monaco")
        #expect(ordinary.warnings.isEmpty)

        let trimmed = load("{\"fontName\": \"  SF Mono\\n\"}")
        #expect(trimmed.configuration.fontName == "SF Mono")
        #expect(trimmed.configuration.jsonObject["fontName"] as? String == "SF Mono")
        #expect(trimmed.warnings.isEmpty)
    }

    @Test func emptyWhitespaceAndWrongTypeFontNamesUseMenlo() {
        for value in ["\"\"", "\" \\t\\n \"", "false", "null"] {
            let result = load("{\"fontName\": \(value)}")
            #expect(result.configuration.fontName == "Menlo")
            #expect(warning(result, for: "fontName", containing: "using Menlo"))
        }
    }

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

    // MARK: Cowfile list decoding

    @Test func emptyCowfileArrayIsIntentionalAndQuiet() {
        let result = load("{\"cowfiles\": []}")
        #expect(result.configuration.cowfiles.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test func cowfileArrayPreservesExactOrderedNames() {
        let result = load("{\"cowfiles\": [\"Tux\", \"dragon.cow\", \" tux \"], \"randomCow\": false}")
        #expect(result.configuration.cowfiles == ["Tux", "dragon.cow", " tux "])
        #expect(!result.configuration.randomCow)
        #expect(result.warnings.isEmpty, "membership belongs to the runtime library")
    }

    @Test func mixedCowfileArrayWarnsByExactIndexAndKeepsStrings() {
        let result = load("""
        {"cowfiles": ["tux", 12, "dragon", null, false, "default"], "wrapWidth": 60}
        """)
        #expect(result.configuration.cowfiles == ["tux", "dragon", "default"])
        #expect(result.configuration.wrapWidth == 60)
        for index in [1, 3, 4] {
            #expect(result.warnings.contains {
                $0.contains("cowfiles[\(index)]") && $0.contains("ignored")
            })
        }
        #expect(result.warnings.count == 3)
    }

    @Test func duplicateCowfilesAreRemovedAfterTheirFirstExactOccurrence() {
        let result = load("""
        {"cowfiles": ["tux", "dragon", "tux", "TUX", "dragon", "default"]}
        """)
        #expect(result.configuration.cowfiles == ["tux", "dragon", "TUX", "default"])
        #expect(result.warnings.contains {
            $0.contains("cowfiles[2]") && $0.contains("'tux'")
        })
        #expect(result.warnings.contains {
            $0.contains("cowfiles[4]") && $0.contains("'dragon'")
        })
        #expect(result.warnings.count == 2)
    }

    @Test func nonArrayCowfilesUseTheDefaultWithoutDiscardingSiblings() {
        for value in ["\"tux\"", "123", "null", "true", "{}"] {
            let result = load("{\"cowfiles\": \(value), \"transition\": \"none\"}")
            #expect(result.configuration.cowfiles == Configuration().cowfiles)
            #expect(result.configuration.transition == "none")
            #expect(warning(result, for: "cowfiles", containing: "using default"))
        }
    }

    @Test func normalizedCowfileListRoundTripsExactly() {
        let loaded = load("{\"cowfiles\": [\"tux\", 1, \"dragon\", \"tux\"]}")
        let roundTrip = Configuration.load(object: loaded.configuration.jsonObject)
        #expect(roundTrip.configuration.cowfiles == ["tux", "dragon"])
        #expect(roundTrip.warnings.isEmpty)
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
        configuration.eyes = "ABCD"
        configuration.tongue = "Q "
        configuration.balloonStyle = "random"
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

    @Test func documentedExampleRoundTripsExactlyWithoutWarnings() throws {
        let url = GoldenTests.repositoryRoot.appendingPathComponent("docs/config.example.json")
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data)
        let object = try #require(parsed as? [String: Any])
        let result = Configuration.load(data: data)

        #expect(result.warnings.isEmpty)
        #expect(result.configuration == Configuration())
        #expect(NSDictionary(dictionary: result.configuration.jsonObject).isEqual(to: object))
    }

    /// An unset theme means "use my own colors". Writing it as "" would both warn on every
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
        // Optional values are absent by default and covered by their own tests above.
        let written = Set(Configuration().jsonObject.keys)
        for key in Configuration.knownKeys where !["theme", "eyes", "tongue"].contains(key) {
            #expect(written.contains(key), "\(key) is never written back")
        }
        for key in written {
            #expect(Configuration.knownKeys.contains(key), "\(key) is written but never read")
        }
    }

    @Test func knownKeysCoverEveryConfigurableField() {
        // A field added without its key would be read from the file and then reported as a
        // key Cowsaver does not know.
        #expect(Configuration.knownKeys.count == 20)
        #expect(Set(Configuration.knownKeys).count == Configuration.knownKeys.count)
    }

    /// A named theme supplies both colors, so the default one has to step aside for a file
    /// that states colors of its own.
    @Test func colorsInTheFileBeatTheDefaultTheme() {
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

    private func balloonMode(of block: String) -> BalloonMode {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.count > 1 && lines[1].first == "(" ? .think : .say
    }

    private func cowFixtureDirectory(_ names: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowsaver-engine-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names {
            let source = "$the_cow = <<'EOC';\n\(name)-fixture-cow\nEOC\n"
            try Data(source.utf8).write(
                to: directory.appendingPathComponent(name).appendingPathExtension("cow")
            )
        }
        return directory
    }

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

    @Test func partialConfiguredMatchesKeepOrderAndReportEveryUnavailableName() throws {
        let cows = try cowFixtureDirectory(["alpha", "beta"])
        defer { try? FileManager.default.removeItem(at: cows) }

        var configuration = Configuration()
        configuration.randomCow = false
        configuration.cowfiles = ["missing-first", "beta", "alpha", "missing-last"]
        let engine = CowsaverEngine(
            configuration: configuration,
            cowDirectories: [cows],
            seed: 2
        )
        #expect(!engine.diagnostics.usingBuiltInCow)
        #expect(engine.diagnostics.notes.contains {
            $0 == "unavailable configured cowfiles: missing-first, missing-last"
        })
        #expect(engine.nextBlock().contains("beta-fixture-cow"))
    }

    @Test func allInvalidConfiguredNamesUseAvailableDefaultCowsFirst() throws {
        let cows = try cowFixtureDirectory(["other", "tux", "default"])
        defer { try? FileManager.default.removeItem(at: cows) }

        var configuration = Configuration()
        configuration.randomCow = false
        configuration.cowfiles = ["missing", "also-missing"]
        let engine = CowsaverEngine(configuration: configuration, cowDirectories: [cows], seed: 3)

        #expect(engine.nextBlock().contains("default-fixture-cow"),
                "the first available name in the documented default order is pinned")
        #expect(engine.diagnostics.notes.contains {
            $0 == "no configured cowfiles loaded; using default cowfiles: default, tux"
        })
    }

    @Test func missingConfiguredAndDefaultCowsUseAllAvailableCows() throws {
        let cows = try cowFixtureDirectory(["zeta", "alpha"])
        defer { try? FileManager.default.removeItem(at: cows) }

        var configuration = Configuration()
        configuration.randomCow = false
        configuration.cowfiles = ["missing"]
        let engine = CowsaverEngine(configuration: configuration, cowDirectories: [cows], seed: 4)

        #expect(engine.nextBlock().contains("alpha-fixture-cow"),
                "all-library fallback is sorted and deterministic")
        #expect(engine.diagnostics.notes.contains {
            $0 == "no configured or default cowfiles loaded; using all 2 available cowfiles"
        })
    }

    @Test func emptyCowfileListUsesEveryAvailableCow() throws {
        let cows = try cowFixtureDirectory(["zeta", "alpha"])
        defer { try? FileManager.default.removeItem(at: cows) }

        var configuration = Configuration()
        configuration.cowfiles = []
        configuration.randomCow = false
        let engine = CowsaverEngine(
            configuration: configuration,
            cowDirectories: [cows],
            seed: 5
        )
        #expect(engine.nextBlock().contains("alpha-fixture-cow"))
        #expect(!engine.diagnostics.usingBuiltInCow)
        #expect(!engine.diagnostics.notes.contains { $0.contains("configured cowfiles") })
    }

    @Test func directDuplicateCowfilesAreIgnoredBeforeSelection() throws {
        let cows = try cowFixtureDirectory(["alpha", "beta"])
        defer { try? FileManager.default.removeItem(at: cows) }

        var configuration = Configuration()
        configuration.cowfiles = ["beta", "beta", "alpha", "beta"]
        let engine = CowsaverEngine(configuration: configuration, cowDirectories: [cows], seed: 6)
        let blocks = (0 ..< 4).map { _ in engine.nextBlock() }

        #expect(blocks.allSatisfy {
            $0.contains("alpha-fixture-cow") || $0.contains("beta-fixture-cow")
        })
        #expect(blocks.contains { $0.contains("alpha-fixture-cow") })
        #expect(blocks.contains { $0.contains("beta-fixture-cow") })
        #expect(engine.diagnostics.notes.filter { $0.contains("duplicate configured cowfile") }.count == 2)
    }

    @Test func randomCowFalsePinsFirstLoadableConfiguredName() throws {
        let cows = try cowFixtureDirectory(["alpha", "beta"])
        defer { try? FileManager.default.removeItem(at: cows) }

        var configuration = Configuration()
        configuration.randomCow = false
        configuration.cowfiles = ["missing", "beta", "alpha"]
        let engine = CowsaverEngine(configuration: configuration, cowDirectories: [cows], seed: 7)
        let blocks = (0 ..< 4).map { _ in engine.nextBlock() }

        #expect(blocks.allSatisfy { $0.contains("beta-fixture-cow") })
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

    @Test func randomBalloonSelectionIsSeededIncludesBothStylesAndAllowsRepeats() {
        var configuration = Configuration()
        configuration.balloonStyle = "random"
        configuration.randomCow = false
        configuration.cowfiles = ["default"]

        func modes(seed: UInt64) -> [BalloonMode] {
            let engine = CowsaverEngine(
                configuration: configuration,
                cowDirectories: [resources.appendingPathComponent("cows")],
                fortuneDirectories: [resources.appendingPathComponent("fortune-curated")],
                seed: seed
            )
            return (0 ..< 40).map { _ in balloonMode(of: engine.nextBlock()) }
        }

        let first = modes(seed: 2468)
        #expect(first == modes(seed: 2468), "the same seed reproduces the balloon sequence")
        #expect(Set(first.map(\.rawValue)) == ["say", "think"])
        #expect(zip(first, first.dropFirst()).contains { $0.0 == $0.1 },
                "independent equal-probability choices permit adjacent repeats")
    }

    @Test func adaptiveCandidatesSpendOnlyOneRandomBalloonChoicePerBlock() {
        var configuration = Configuration()
        configuration.balloonStyle = "random"
        configuration.randomCow = false
        configuration.cowfiles = ["stegosaurus"]
        let directory = resources.appendingPathComponent("cows")
        let fortunes = resources.appendingPathComponent("fortune-curated")
        let plain = CowsaverEngine(configuration: configuration, cowDirectories: [directory],
                                   fortuneDirectories: [fortunes], seed: 97531)
        let adaptive = CowsaverEngine(configuration: configuration, cowDirectories: [directory],
                                      fortuneDirectories: [fortunes], seed: 97531)
        let canvas = AdaptiveWrap.Canvas(aspectRatio: 16.0 / 10.0, cellAspectRatio: 0.52)

        for rotation in 0 ..< 20 {
            #expect(balloonMode(of: plain.nextBlock()) ==
                    balloonMode(of: adaptive.nextBlock(fitting: canvas)),
                    "rotation \(rotation) must use the one block-level choice")
        }
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

    /// More resource-specific problems than the 50-detail cap must still leave the
    /// complete structured count intact, while the logged sequence stays bounded, names
    /// what was suppressed, and never echoes any fixture content back.
    @Test func moreThanFiftyResourceProblemsStayBoundedWithACompleteCountAndNoContentLeak() throws {
        let fortuneDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowsaver-engine-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fortuneDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fortuneDirectory) }
        for index in 0 ..< 60 {
            try Data([0xFF, 0xFE]).write(to: fortuneDirectory.appendingPathComponent("bad\(index)"))
        }

        let engine = CowsaverEngine(
            configuration: Configuration(),
            cowDirectories: [resources.appendingPathComponent("cows")],
            fortuneDirectories: [fortuneDirectory],
            seed: 8
        )

        #expect(engine.diagnostics.fortuneStatistics.invalidUTF8FilesSkipped == 60,
                "the structured count stays complete even past the logging cap")
        let resourceDetailLines = engine.diagnostics.messages.filter { $0.contains("invalid UTF-8") }
        #expect(resourceDetailLines.count == 50)
        #expect(engine.diagnostics.messages.contains {
            $0.contains("10 additional resource-specific detail")
        })
        #expect(engine.diagnostics.messages.allSatisfy { !$0.contains("0xFF") && !$0.contains("ÿ") })
        #expect(engine.diagnostics.usingBuiltInFortunes,
                "a wholly invalid personal collection still falls back to the built-in set")
    }

    /// The same authoritative sequence carries a rejected cowfile, a fortune loader
    /// recovery event, and a fallback note together, with nothing repeated between them.
    @Test func messagesCombineCowfileFortuneAndFallbackCategoriesWithoutDuplicates() throws {
        let cows = try cowFixtureDirectory([])
        defer { try? FileManager.default.removeItem(at: cows) }
        // Real Perl beyond the supported static heredoc form (see CoreTests.rejectsCowfilesCarryingRealPerl).
        try Data("$extra = chop($eyes);\n$the_cow = <<EOC;\nx\nEOC\n".utf8).write(
            to: cows.appendingPathComponent("broken").appendingPathExtension("cow")
        )

        let fortuneDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowsaver-engine-messages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fortuneDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fortuneDirectory) }
        try Data([0xFF]).write(to: fortuneDirectory.appendingPathComponent("bad"))

        let engine = CowsaverEngine(
            configuration: Configuration(), cowDirectories: [cows],
            fortuneDirectories: [fortuneDirectory], seed: 9
        )

        #expect(engine.diagnostics.usingBuiltInCow)
        #expect(engine.diagnostics.usingBuiltInFortunes)
        #expect(!engine.diagnostics.cowfilesRejected.isEmpty)
        #expect(engine.diagnostics.messages.contains { $0.contains("cowfile broken:") })
        #expect(engine.diagnostics.messages.contains { $0.contains("bad") && $0.contains("invalid UTF-8") })
        #expect(engine.diagnostics.messages.contains { $0 == "no fortunes found; using the built-in set" })
        #expect(engine.diagnostics.messages.allSatisfy { !$0.contains("chop") && !$0.contains("$extra") },
                "the rejected cowfile's own source line must never appear")
        #expect(Set(engine.diagnostics.messages).count == engine.diagnostics.messages.count,
                "no message should be duplicated across categories")
    }
}
