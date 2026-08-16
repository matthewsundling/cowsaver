import Foundation

/// A colour, kept here rather than in the AppKit layer so it can be parsed and tested
/// without a window server.
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
        var text = hex.trimmingCharacters(in: .whitespaces)
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
    public var foreground: String = "#33FF66"
    public var background: String = "#000000"
    public var theme: String?
    public var transition: String = "fade"
    public var reposition: Bool = true
    /// Widen the balloon when that makes the text bigger. See `AdaptiveWrap`.
    public var adaptiveWrap: Bool = true
    /// How tall a fortune may be, in lines wrapped at `wrapWidth`. `0` means no limit.
    public var maxFortuneLines: Int = 60
    public var weightByFile: Bool = false

    public init() {}

    /// Every key this configuration understands. Used to pull the matching values out of
    /// `ScreenSaverDefaults` before the config file is layered on top.
    public static let knownKeys = [
        "rotationSeconds", "wrapWidth", "cowfiles", "randomCow", "face", "balloonStyle",
        "fontName", "fontSize", "foreground", "background", "theme", "transition",
        "reposition", "adaptiveWrap", "maxFortuneLines", "weightByFile",
    ]

    // MARK: Derived values, all clamped

    /// Clamped so a hand-edited config cannot produce a busy loop. One second is already
    /// far more often than anything here needs to happen.
    public var rotationInterval: Double { min(max(rotationSeconds, 1), 86_400) }

    /// `Text::Wrap` requires at least 2; absurdly wide wrapping just wastes the screen.
    public var effectiveWrapWidth: Int { min(max(wrapWidth, 2), 500) }

    public var balloonMode: BalloonMode {
        balloonStyle.lowercased() == "think" ? .think : .say
    }

    public var faceModes: Set<FaceMode> {
        // Accepts "dead", "d", or "dead,young".
        let tokens = face.lowercased().split(whereSeparator: { $0 == "," || $0 == " " })
        var modes: Set<FaceMode> = []
        for token in tokens {
            if let mode = FaceMode(rawValue: String(token)) {
                modes.insert(mode)
            } else if token.count == 1, let first = token.first,
                      let mode = FaceMode.fromFlag(first) {
                modes.insert(mode)
            }
        }
        return modes
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
            "foreground": foreground,
            "background": background,
            "transition": transition,
            "reposition": reposition,
            "adaptiveWrap": adaptiveWrap,
            "maxFortuneLines": maxFortuneLines,
            "weightByFile": weightByFile,
        ]
        // Omit an unset theme so raw foreground and background values remain active.
        if let theme { object["theme"] = theme }
        return object
    }

    public var fortuneLoadOptions: FortuneLoadOptions {
        FortuneLoadOptions(maxLines: max(maxFortuneLines, 0),
                           wrapColumns: effectiveWrapWidth)
    }
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

    /// Receives the merged configuration layers: built-in defaults, `ScreenSaverDefaults`,
    /// then `config.json`, whose values have the highest priority.
    static func load(object: [String: Any]) -> LoadResult {
        var configuration = Configuration()
        var warnings: [String] = []

        // Decode fields independently so one invalid value does not discard the rest.
        func number(_ key: String) -> Double? {
            if let value = object[key] as? Double { return value }
            if let value = object[key] as? Int { return Double(value) }
            if object[key] != nil { warnings.append("\(key): expected a number, ignoring") }
            return nil
        }
        func string(_ key: String) -> String? {
            if let value = object[key] as? String { return value }
            if object[key] != nil { warnings.append("\(key): expected a string, ignoring") }
            return nil
        }
        func boolean(_ key: String) -> Bool? {
            if let value = object[key] as? Bool { return value }
            if object[key] != nil { warnings.append("\(key): expected true or false, ignoring") }
            return nil
        }

        if let value = number("rotationSeconds") { configuration.rotationSeconds = value }
        if let value = number("wrapWidth") { configuration.wrapWidth = Int(value) }
        if let value = object["cowfiles"] as? [String] { configuration.cowfiles = value }
        else if object["cowfiles"] != nil { warnings.append("cowfiles: expected a list of names, ignoring") }
        if let value = boolean("randomCow") { configuration.randomCow = value }
        if let value = string("face") { configuration.face = value }
        if let value = string("balloonStyle") { configuration.balloonStyle = value }
        if let value = string("fontName") { configuration.fontName = value }
        if let value = number("fontSize") { configuration.fontSize = value }
        if let value = string("foreground") { configuration.foreground = value }
        if let value = string("background") { configuration.background = value }
        if let value = string("theme") { configuration.theme = value }
        if let value = string("transition") { configuration.transition = value }
        if let value = boolean("reposition") { configuration.reposition = value }
        if let value = boolean("adaptiveWrap") { configuration.adaptiveWrap = value }
        if let value = number("maxFortuneLines") { configuration.maxFortuneLines = Int(value) }
        if let value = boolean("weightByFile") { configuration.weightByFile = value }

        if let name = configuration.theme, ThemePreset.named(name) == nil {
            warnings.append("theme: unknown preset '\(name)'; using the colours as given")
            configuration.theme = nil
        }
        if ThemeColor(hex: configuration.foreground) == nil {
            warnings.append("foreground: '\(configuration.foreground)' is not a hex colour")
        }
        if ThemeColor(hex: configuration.background) == nil {
            warnings.append("background: '\(configuration.background)' is not a hex colour")
        }

        return LoadResult(configuration: configuration, warnings: warnings)
    }
}
