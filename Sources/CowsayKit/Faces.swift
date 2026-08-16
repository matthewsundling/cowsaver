import Foundation

/// The eight appearance modes from cowsay's `construct_face`.
///
/// Note `tired` is `-t` and means **tired eyes** (`--`). It is not a thought bubble —
/// that is `cowthink`, a separate program selected by `$0 =~ /think/i`. `BalloonMode`
/// therefore represents bubble shape independently of face flags.
public enum FaceMode: String, CaseIterable, Sendable {
    case borg, dead, greedy, paranoid, stoned, tired, wired, young

    /// The single-letter flag real cowsay uses, for CLI parsing and golden manifests.
    public var flag: Character {
        switch self {
        case .borg: return "b"
        case .dead: return "d"
        case .greedy: return "g"
        case .paranoid: return "p"
        case .stoned: return "s"
        case .tired: return "t"
        case .wired: return "w"
        case .young: return "y"
        }
    }

    public static func fromFlag(_ c: Character) -> FaceMode? {
        FaceMode.allCases.first { $0.flag == c }
    }
}

public struct Face: Equatable, Sendable {
    public var eyes: ByteString
    public var tongue: ByteString

    public init(eyes: ByteString, tongue: ByteString) {
        self.eyes = eyes
        self.tongue = tongue
    }

    public static let `default` = Face(eyes: Bytes.from("oo"), tongue: Bytes.from("  "))

    /// Reproduces cowsay's ordering exactly, which matters more than it looks:
    ///
    /// - `-e` and `-T` are applied **first** (lines 58–59), truncated to two bytes by
    ///   `substr($opts{'e'}, 0, 2)`. Any face flag therefore *overrides* a custom `-e`.
    /// - `construct_face` is a run of plain `if`s, not `elsif`, so with several flags the
    ///   **last one in this order wins** for the eyes.
    /// - `dead` and `stoned` also set the tongue to `"U "`, and they do so regardless of
    ///   whether a later flag replaces the eyes.
    public static func construct(
        customEyes: ByteString? = nil,
        customTongue: ByteString? = nil,
        modes: Set<FaceMode> = []
    ) -> Face {
        var eyes = customEyes.map { ByteString($0.prefix(2)) } ?? Face.default.eyes
        var tongue = customTongue.map { ByteString($0.prefix(2)) } ?? Face.default.tongue

        // Order is cowsay's, not alphabetical by accident — see construct_face.
        for mode in [FaceMode.borg, .dead, .greedy, .paranoid, .stoned, .tired, .wired, .young]
        where modes.contains(mode) {
            switch mode {
            case .borg:     eyes = Bytes.from("==")
            case .dead:     eyes = Bytes.from("xx"); tongue = Bytes.from("U ")
            case .greedy:   eyes = Bytes.from("$$")
            case .paranoid: eyes = Bytes.from("@@")
            case .stoned:   eyes = Bytes.from("**"); tongue = Bytes.from("U ")
            case .tired:    eyes = Bytes.from("--")
            case .wired:    eyes = Bytes.from("OO")
            case .young:    eyes = Bytes.from("..")
            }
        }
        return Face(eyes: eyes, tongue: tongue)
    }
}
