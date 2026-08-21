import CoreFoundation
import Foundation

/// A colour, kept here rather than in the AppKit layer.
///
/// This lets it be parsed and tested without a window server.
public struct ThemeColor: Equatable, Sendable {
    public let red: Double, green: Double, blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Accepts `#RGB`, `#RRGGBB`, with or without the `#`. Returns nil rather than
    /// throwing: a bad colour in a config file must degrade to the default, not take the
    /// screensaver down.
    public init?(hex: String) {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }

        let digits = Array(text.lowercased())
        guard digits.allSatisfy({ $0.isHexDigit }) else { return nil }

        func value(_ slice: [Character]) -> Double? {
            guard let raw = UInt8(String(slice), radix: 16) else { return nil }
            return Double(raw) / 255.0
        }

        switch digits.count {
        case 3:
            guard let r = value([digits[0], digits[0]]),
                  let g = value([digits[1], digits[1]]),
                  let b = value([digits[2], digits[2]]) else { return nil }
            self.init(red: r, green: g, blue: b)
        case 6:
            guard let r = value(Array(digits[0 ..< 2])),
                  let g = value(Array(digits[2 ..< 4])),
                  let b = value(Array(digits[4 ..< 6])) else { return nil }
            self.init(red: r, green: g, blue: b)
        default:
            return nil
        }
    }
}

/// A named foreground and background colour scheme.
public struct ThemePreset: Sendable {
    public let name: String
    public let foreground: String
    public let background: String

    public static let all: [ThemePreset] = [
        .init(name: "green-phosphor", foreground: "#33FF66", background: "#000000"),
        .init(name: "amber",          foreground: "#FFB000", background: "#000000"),
        .init(name: "paperwhite",     foreground: "#2B2B2B", background: "#F5F2E8"),
        .init(name: "solarized-dark", foreground: "#93A1A1", background: "#002B36"),
    ]

    public static func named(_ name: String) -> ThemePreset? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Cowsaver's settings.
///
/// `config.json` is the persisted configuration shared by the saver and standalone app.
///
/// Every field has a default and every field decodes independently: a config file with one
/// misspelled key, one wrong type, or one absent field still yields a working
/// configuration for everything else. Nothing here throws.
public struct Configuration: Equatable, Sendable {
    public var rotationSeconds: Double = 45
    public var wrapWidth: Int = 40
    public var cowfiles: [String] = ["stegosaurus", "default", "tux", "dragon"]
    public var randomCow: Bool = true
    public var face: String = "default"
    public var balloonStyle: String = "say"
    public var fontName: String = "Menlo"
    /// `0` means auto-fit: pick the largest size that fits, once per rotation.
    public var fontSize: Double = 0
    /// How far below the fitted size a rotation may be drawn. `0` draws every rotation at
    /// the fitted size. Auto-fit only: a pinned `fontSize` is an explicit choice.
    public var sizeVariation: Double = 0
    public var foreground: String = "#33FF66"
    public var background: String = "#000000"
    /// A named preset, which supplies both colours. Cowsaver ships on `green-phosphor`, so
    /// restoring defaults lands on a named theme rather than on a pair of loose colours. A
    /// file that sets `foreground` or `background` without naming a theme clears this, so
    /// colours written by hand still win.
    public var theme: String? = "green-phosphor"
    public var transition: String = "fade"
    public var reposition: Bool = true
    /// Widen the balloon when that makes the text bigger. See `AdaptiveWrap`.
    public var adaptiveWrap: Bool = true
    /// How tall a fortune may be, in lines wrapped at `wrapWidth`. `0` means no limit.
    public var maxFortuneLines: Int = 60
    public var weightByFile: Bool = false
    /// Draws a border on the view bounds and a contrasting one on the text layer.
    ///
    /// Tells host-geometry bugs from layout bugs in a screenshot. Config-file only;
    /// not exposed in the Options sheet.
    public var debugFrame: Bool = false

    public init() {}

    /// Every key this configuration understands. A key outside this list warns on load, and
    /// the documentation tests require each one to appear in the reference and the example.
    public static let knownKeys = [
        "rotationSeconds", "wrapWidth", "cowfiles", "randomCow", "face", "balloonStyle",
        "fontName", "fontSize", "sizeVariation", "foreground", "background", "theme",
        "transition", "reposition", "adaptiveWrap", "maxFortuneLines", "weightByFile",
        "debugFrame",
    ]

    /// Shared operating bounds for file decoding and defensive use of configurations built
    /// directly in code. The settings window can use the same limits when it validates input.
    public static let rotationSecondsRange = 1 ... 600
    public static let wrapWidthRange = 2 ... 500
    public static let pinnedFontSizeRange = 6.0 ... 144.0
    public static let sizeVariationRange = 0.0 ... 0.9
    public static let maxFortuneLinesRange = 0 ... 100

    // MARK: Derived values, all clamped

    /// A direct configuration can bypass file decoding, so this is always a finite safe
    /// interval for the timer even when the stored value is non-finite.
    public var rotationInterval: Double {
        guard rotationSeconds.isFinite else { return Configuration().rotationSeconds }
        return min(max(rotationSeconds, Double(Self.rotationSecondsRange.lowerBound)),
                   Double(Self.rotationSecondsRange.upperBound))
    }

    /// `Text::Wrap` requires at least two columns, and 500 is the widest useful balloon.
    public var effectiveWrapWidth: Int {
        min(max(wrapWidth, Self.wrapWidthRange.lowerBound), Self.wrapWidthRange.upperBound)
    }

    /// Non-finite variation would poison layout arithmetic, so it behaves like the default.
    public var effectiveSizeVariation: Double {
        guard sizeVariation.isFinite else { return Configuration().sizeVariation }
        return min(max(sizeVariation, Self.sizeVariationRange.lowerBound),
                   Self.sizeVariationRange.upperBound)
    }

    /// The safe pinned point size. Zero retains auto-fit; all other usable values are in the
    /// documented pinned range before AppKit receives them.
    public var effectivePinnedFontSize: Double {
        guard fontSize.isFinite else { return 0 }
        guard fontSize > 0 else { return 0 }
        return min(max(fontSize, Self.pinnedFontSizeRange.lowerBound),
                   Self.pinnedFontSizeRange.upperBound)
    }

    public var balloonMode: BalloonMode {
        balloonStyle.lowercased() == "think" ? .think : .say
    }

    public var faceModes: Set<FaceMode> {
        parseFace(face).modes
    }

    /// A named theme wins over raw hex values, so `"theme": "amber"` does what it looks
    /// like without also having to edit two colours.
    public var resolvedForeground: ThemeColor {
        if let preset = theme.flatMap(ThemePreset.named),
           let colour = ThemeColor(hex: preset.foreground) { return colour }
        return ThemeColor(hex: foreground) ?? ThemeColor(red: 0.2, green: 1.0, blue: 0.4)
    }

    public var resolvedBackground: ThemeColor {
        if let preset = theme.flatMap(ThemePreset.named),
           let colour = ThemeColor(hex: preset.background) { return colour }
        return ThemeColor(hex: background) ?? ThemeColor(red: 0, green: 0, blue: 0)
    }

    public var wantsTransition: Bool { transition.lowercased() != "none" }

    /// This configuration as a JSON object, ready to be written to `config.json`.
    ///
    /// Kept beside the loader so configuration tests can verify that every persisted key is
    /// both written and read.
    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "rotationSeconds": rotationSeconds,
            "wrapWidth": wrapWidth,
            "cowfiles": cowfiles,
            "randomCow": randomCow,
            "face": face,
            "balloonStyle": balloonStyle,
            "fontName": fontName,
            "fontSize": fontSize,
            "sizeVariation": sizeVariation,
            "foreground": foreground,
            "background": background,
            "transition": transition,
            "reposition": reposition,
            "adaptiveWrap": adaptiveWrap,
            "maxFortuneLines": maxFortuneLines,
            "weightByFile": weightByFile,
            "debugFrame": debugFrame,
        ]
        // Omit an unset theme so raw foreground and background values remain active.
        if let theme { object["theme"] = theme }
        return object
    }

    public var fortuneLoadOptions: FortuneLoadOptions {
        FortuneLoadOptions(maxLines: min(max(maxFortuneLines, Self.maxFortuneLinesRange.lowerBound),
                                         Self.maxFortuneLinesRange.upperBound),
                           wrapColumns: effectiveWrapWidth)
    }
}

private struct ParsedFace {
    let normalized: String
    let modes: Set<FaceMode>
    let rejectedTokens: [String]
    let recognizedAnyToken: Bool
}

/// Keep file normalization and the defensive behavior for directly constructed
/// configurations on one token grammar.
private func parseFace(_ value: String) -> ParsedFace {
    let tokens = value.split(whereSeparator: { $0 == "," || $0.isWhitespace })
    var normalizedModes: [String] = []
    var modes: Set<FaceMode> = []
    var rejectedTokens: [String] = []
    var recognizedDefault = false

    for rawToken in tokens {
        let token = rawToken.lowercased()
        if token == "default" {
            recognizedDefault = true
        } else if let mode = FaceMode(rawValue: token) {
            normalizedModes.append(token)
            modes.insert(mode)
        } else if token.count == 1, let flag = token.first,
                  let mode = FaceMode.fromFlag(flag) {
            normalizedModes.append(token)
            modes.insert(mode)
        } else {
            rejectedTokens.append(String(rawToken))
        }
    }

    let recognizedAnyToken = recognizedDefault || !normalizedModes.isEmpty
    return ParsedFace(
        normalized: normalizedModes.isEmpty ? "default" : normalizedModes.joined(separator: ", "),
        modes: modes,
        rejectedTokens: rejectedTokens,
        recognizedAnyToken: recognizedAnyToken
    )
}

// MARK: - Loading

public extension Configuration {
    struct LoadResult: Sendable {
        public let configuration: Configuration
        /// Human-readable notes about anything ignored. The screensaver logs these; it
        /// never surfaces them as an error, because there is no one to show an error to.
        public let warnings: [String]

        public init(configuration: Configuration, warnings: [String]) {
            self.configuration = configuration
            self.warnings = warnings
        }
    }

    /// Parse a config file. Missing, unreadable, malformed, and partially invalid input
    /// yields usable defaults plus warnings.
    static func load(contentsOf url: URL) -> LoadResult {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return LoadResult(configuration: Configuration(),
                              warnings: ["no config file at \(url.path); using defaults"])
        }
        return load(data: data)
    }

    static func load(data: Data) -> LoadResult {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return LoadResult(configuration: Configuration(),
                              warnings: ["config file is not valid JSON; using defaults"])
        }
        guard let object = parsed as? [String: Any] else {
            return LoadResult(configuration: Configuration(),
                              warnings: ["config file is not a JSON object; using defaults"])
        }
        return load(object: object)
    }

    /// Decode the contents of `config.json`, which is the whole configuration. A key it does
    /// not hold keeps the built-in default; a key nothing here reads warns rather than
    /// passing unnoticed.
    static func load(object: [String: Any]) -> LoadResult {
        var configuration = Configuration()
        let defaults = configuration
        var warnings: [String] = []

        func format(_ value: Double) -> String {
            String(format: "%g", value)
        }

        // JSON booleans are NSNumbers too, so their Core Foundation type distinguishes them
        // from JSON numbers before any conversion or bound check happens.
        func numericValue(_ key: String) -> Double? {
            guard let raw = object[key] else { return nil }
            guard let value = raw as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID() else {
                warnings.append("\(key): expected a number; using default")
                return nil
            }
            let decoded = value.doubleValue
            guard decoded.isFinite else {
                warnings.append("\(key): expected a finite number; using default")
                return nil
            }
            return decoded
        }
        func wholeNumber(_ key: String, in range: ClosedRange<Int>) -> Int? {
            guard let decoded = numericValue(key) else { return nil }
            guard decoded.rounded(.towardZero) == decoded else {
                warnings.append("\(key): expected a whole number; using default")
                return nil
            }
            // Compare while this is still a Double. Even a huge finite JSON value then clamps
            // before conversion to Int, so it cannot trap.
            if decoded < Double(range.lowerBound) {
                warnings.append("\(key): clamped to \(range.lowerBound)")
                return range.lowerBound
            }
            if decoded > Double(range.upperBound) {
                warnings.append("\(key): clamped to \(range.upperBound)")
                return range.upperBound
            }
            return Int(decoded)
        }
        func boundedNumber(_ key: String, in range: ClosedRange<Double>) -> Double? {
            guard let decoded = numericValue(key) else { return nil }
            if decoded < range.lowerBound {
                warnings.append("\(key): clamped to \(format(range.lowerBound))")
                return range.lowerBound
            }
            if decoded > range.upperBound {
                warnings.append("\(key): clamped to \(format(range.upperBound))")
                return range.upperBound
            }
            return decoded
        }
        func fontSize(_ key: String) -> Double? {
            guard let decoded = numericValue(key) else { return nil }
            if decoded < 0 {
                warnings.append("\(key): clamped to 0")
                return 0
            }
            if decoded > 0 && decoded < Self.pinnedFontSizeRange.lowerBound {
                warnings.append("\(key): clamped to \(format(Self.pinnedFontSizeRange.lowerBound))")
                return Self.pinnedFontSizeRange.lowerBound
            }
            if decoded > Self.pinnedFontSizeRange.upperBound {
                warnings.append("\(key): clamped to \(format(Self.pinnedFontSizeRange.upperBound))")
                return Self.pinnedFontSizeRange.upperBound
            }
            return decoded
        }
        func boolean(_ key: String) -> Bool? {
            guard let raw = object[key] else { return nil }
            guard let value = raw as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else {
                warnings.append("\(key): expected true or false; using default")
                return nil
            }
            return value.boolValue
        }
        func categorical(_ key: String, allowed: [String], default defaultValue: String) -> String? {
            guard let raw = object[key] else { return nil }
            guard let value = raw as? String else {
                warnings.append("\(key): expected a string; using \(defaultValue)")
                return defaultValue
            }
            guard let canonical = allowed.first(where: {
                $0.caseInsensitiveCompare(value) == .orderedSame
            }) else {
                warnings.append("\(key): unsupported value '\(value)'; using \(defaultValue)")
                return defaultValue
            }
            return canonical
        }
        func face() -> String? {
            guard let raw = object["face"] else { return nil }
            guard let value = raw as? String else {
                warnings.append("face: expected a string; using default")
                return defaults.face
            }
            let parsed = parseFace(value)
            for token in parsed.rejectedTokens {
                warnings.append("face: rejected token '\(token)'")
            }
            if !parsed.recognizedAnyToken {
                warnings.append("face: no recognized tokens remain; using default")
            }
            return parsed.normalized
        }
        func fontName() -> String? {
            guard let raw = object["fontName"] else { return nil }
            guard let value = raw as? String else {
                warnings.append("fontName: expected a non-empty string; using \(defaults.fontName)")
                return defaults.fontName
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                warnings.append("fontName: expected a non-empty string; using \(defaults.fontName)")
                return defaults.fontName
            }
            return trimmed
        }
        func color(_ key: String, default defaultValue: String) -> String? {
            guard let raw = object[key] else { return nil }
            guard let value = raw as? String else {
                warnings.append("\(key): expected a hexadecimal colour string; using \(defaultValue)")
                return defaultValue
            }
            guard ThemeColor(hex: value) != nil else {
                warnings.append("\(key): invalid hexadecimal colour '\(value)'; using \(defaultValue)")
                return defaultValue
            }
            return value
        }
        func cowfiles() -> [String]? {
            guard let raw = object["cowfiles"] else { return nil }
            guard let entries = raw as? [Any] else {
                warnings.append(
                    "cowfiles: expected an array; using default \(defaults.cowfiles)"
                )
                return defaults.cowfiles
            }

            var names: [String] = []
            var seen: Set<String> = []
            for (index, entry) in entries.enumerated() {
                guard let name = entry as? String else {
                    warnings.append("cowfiles[\(index)]: expected a string; entry ignored")
                    continue
                }
                guard seen.insert(name).inserted else {
                    warnings.append(
                        "cowfiles[\(index)]: duplicate name '\(name)'; entry ignored"
                    )
                    continue
                }
                names.append(name)
            }
            return names
        }

        if let value = wholeNumber("rotationSeconds", in: Self.rotationSecondsRange) {
            configuration.rotationSeconds = Double(value)
        }
        if let value = wholeNumber("wrapWidth", in: Self.wrapWidthRange) { configuration.wrapWidth = value }
        if let value = cowfiles() { configuration.cowfiles = value }
        if let value = boolean("randomCow") { configuration.randomCow = value }
        if let value = face() { configuration.face = value }
        if let value = categorical("balloonStyle", allowed: ["say", "think"],
                                   default: defaults.balloonStyle) {
            configuration.balloonStyle = value
        }
        if let value = fontName() { configuration.fontName = value }
        if let value = fontSize("fontSize") { configuration.fontSize = value }
        if let value = boundedNumber("sizeVariation", in: Self.sizeVariationRange) {
            configuration.sizeVariation = value
        }
        if let value = color("foreground", default: defaults.foreground) {
            configuration.foreground = value
        }
        if let value = color("background", default: defaults.background) {
            configuration.background = value
        }
        if let value = categorical("theme", allowed: ThemePreset.all.map(\.name),
                                   default: defaults.theme!) {
            configuration.theme = value
        }
        if let value = categorical("transition", allowed: ["fade", "none"],
                                   default: defaults.transition) {
            configuration.transition = value
        }
        if let value = boolean("reposition") { configuration.reposition = value }
        if let value = boolean("adaptiveWrap") { configuration.adaptiveWrap = value }
        if let value = wholeNumber("maxFortuneLines", in: Self.maxFortuneLinesRange) {
            configuration.maxFortuneLines = value
        }
        if let value = boolean("weightByFile") { configuration.weightByFile = value }
        if let value = boolean("debugFrame") { configuration.debugFrame = value }

        // Colours in the file beat the default preset, which would otherwise override every
        // hand-written colour. Naming a theme is how a file asks for a preset instead.
        if object["theme"] == nil,
           object["foreground"] != nil || object["background"] != nil {
            configuration.theme = nil
        }

        // Without this a misspelled key looks exactly like a setting that had no effect.
        // Sorted, so a log grep and a test see the same order every time.
        for key in object.keys.sorted() where !knownKeys.contains(key) {
            warnings.append("\(key): not a setting Cowsaver knows; ignoring it")
        }

        return LoadResult(configuration: configuration, warnings: warnings)
    }
}
