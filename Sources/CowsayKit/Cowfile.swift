import Foundation

/// A parsed cowfile: its `##` attribution header and raw heredoc template.
///
/// The header is preserved because bundled cowfiles use it for artist attribution.
public struct Cowfile: Equatable, Sendable {
    public let name: String
    public let header: [ByteString]
    public let template: ByteString
    /// `false` for a `<<'EOC'` heredoc, where Perl does no variable interpolation.
    public let interpolating: Bool

    public init(name: String, header: [ByteString], template: ByteString, interpolating: Bool) {
        self.name = name
        self.header = header
        self.template = template
        self.interpolating = interpolating
    }
}

public enum CowfileParseError: Error, Equatable, CustomStringConvertible {
    case noHeredoc
    case unterminatedHeredoc(terminator: String)
    /// A cowfile containing real Perl beyond a single heredoc assignment.
    case unsupportedPerl(line: String)
    case truecolor

    public var description: String {
        switch self {
        case .noHeredoc:
            return "no `$the_cow = <<EOC;` heredoc assignment found"
        case .unterminatedHeredoc(let t):
            return "heredoc opened but terminator `\(t)` never appears"
        case .unsupportedPerl(let line):
            return "contains Perl this parser does not implement: `\(line)`"
        case .truecolor:
            return "truecolor cowfile: full of ANSI escapes, unusable in a text layer"
        }
    }
}

public enum CowfileParser {
    /// Parse a cowfile.
    ///
    /// cowsay evaluates cowfiles as Perl. Cowsaver supports static templates: comments,
    /// blank lines, and one `$the_cow` heredoc assignment. It does not execute Perl.
    ///
    /// The parser validates that restricted form instead of searching for selected Perl
    /// keywords. For example, `three-eyes.cow` and `udder.cow` alter `$eyes` with ordinary
    /// assignments rather than control flow:
    ///
    /// ```perl
    /// $extra = chop($eyes);
    /// $eyes .= ($extra x 2);
    /// ```
    ///
    /// Cowsaver bundles the 47 cowfiles that fit this static form. The four cowsay 3.8.4
    /// cowfiles that require Perl are intentionally omitted.
    public static func parse(name: String, contents: ByteString) throws -> Cowfile {
        if name.hasPrefix("truecolor/") { throw CowfileParseError.truecolor }

        let lines = Bytes.split(contents, on: Bytes.lf, dropTrailingEmpty: false)
        var header: [ByteString] = []
        var index = 0
        var opener: (terminator: String, interpolating: Bool)?

        while index < lines.count {
            let line = lines[index]
            if let found = parseHeredocOpener(line) {
                opener = found
                index += 1
                break
            }
            if isBlank(line) {
                index += 1
                continue
            }
            if isComment(line) {
                header.append(line)
                index += 1
                continue
            }
            throw CowfileParseError.unsupportedPerl(line: Bytes.describe(line))
        }

        guard let opener else { throw CowfileParseError.noHeredoc }

        var body: [ByteString] = []
        var terminated = false
        while index < lines.count {
            let line = lines[index]
            index += 1
            if trimmed(line) == Bytes.from(opener.terminator) {
                terminated = true
                break
            }
            body.append(line)
        }
        guard terminated else {
            throw CowfileParseError.unterminatedHeredoc(terminator: opener.terminator)
        }

        // Anything after the heredoc must also be inert.
        while index < lines.count {
            let line = lines[index]
            index += 1
            if isBlank(line) || isComment(line) { continue }
            throw CowfileParseError.unsupportedPerl(line: Bytes.describe(line))
        }

        // A heredoc body always ends with a newline on its final line.
        var template = Bytes.join(body, separator: Bytes.lf)
        if !body.isEmpty { template.append(Bytes.lf) }

        return Cowfile(
            name: name,
            header: header,
            template: template,
            interpolating: opener.interpolating
        )
    }

    /// Render the cow: escapes and `$variable` substitution in **a single left-to-right
    /// pass**.
    ///
    /// Escapes and substitutions share one left-to-right pass. Replacement text is appended
    /// directly and is not scanned again: face modes such as `-g` (`$$`) and `-p` (`@@`)
    /// must remain literal eye text.
    public static func render(
        _ cowfile: Cowfile,
        thoughts: UInt8,
        face: Face
    ) -> ByteString {
        let t = cowfile.template
        var out = ByteString()
        out.reserveCapacity(t.count + 32)

        var i = 0
        while i < t.count {
            let b = t[i]

            if b == Bytes.backslash, i + 1 < t.count {
                // Perl double-quote escapes. An unknown escape yields the bare character,
                // which is how `\-`, `\|` and friends in the shipped cowfiles behave.
                let next = t[i + 1]
                if cowfile.interpolating {
                    switch next {
                    case UInt8(ascii: "n"): out.append(Bytes.lf)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "0"): out.append(0x00)
                    default: out.append(next)
                    }
                } else {
                    // In a '' heredoc Perl only honours \\ and \'; everything else is literal.
                    if next == Bytes.backslash || next == UInt8(ascii: "'") {
                        out.append(next)
                    } else {
                        out.append(b)
                        out.append(next)
                    }
                }
                i += 2
                continue
            }

            if b == Bytes.dollar, cowfile.interpolating,
               let variable = parseVariable(t, at: i) {
                switch variable.name {
                case "thoughts": out.append(thoughts)
                case "eyes":     out.append(contentsOf: face.eyes)
                case "tongue":   out.append(contentsOf: face.tongue)
                default:
                    // Intentional divergence: Perl substitutes an undefined variable with
                    // an empty string; Cowsaver leaves an unsupported reference visible.
                    // Bundled cowfiles use only the three variables handled above.
                    out.append(b)
                    i += 1
                    continue
                }
                i += variable.length
                continue
            }

            out.append(b)
            i += 1
        }
        return out
    }

    // MARK: - Scanning helpers

    /// `^\s*\$the_cow\s*=\s*<<\s*(["']?)(\w+)\1\s*;`
    static func parseHeredocOpener(_ line: ByteString) -> (terminator: String, interpolating: Bool)? {
        var i = 0
        func skipSpaces() { while i < line.count, Bytes.isSpace(line[i]) { i += 1 } }
        func expect(_ s: String) -> Bool {
            let bytes = Bytes.from(s)
            guard i + bytes.count <= line.count, Array(line[i ..< (i + bytes.count)]) == bytes
            else { return false }
            i += bytes.count
            return true
        }

        skipSpaces()
        guard expect("$the_cow") else { return nil }
        skipSpaces()
        guard expect("=") else { return nil }
        skipSpaces()
        guard expect("<<") else { return nil }
        skipSpaces()

        var quote: UInt8?
        if i < line.count, line[i] == UInt8(ascii: "\"") || line[i] == UInt8(ascii: "'") {
            quote = line[i]
            i += 1
        }

        let nameStart = i
        while i < line.count, Bytes.isWordByte(line[i]) { i += 1 }
        guard i > nameStart else { return nil }
        let terminator = Bytes.describe(Array(line[nameStart ..< i]))

        if let quote {
            guard i < line.count, line[i] == quote else { return nil }
            i += 1
        }
        skipSpaces()
        // The trailing semicolon is optional: `sheep.cow` ships as `$the_cow = <<EOC`
        // with none, which Perl accepts because a file's final statement may omit it.
        _ = expect(";")

        return (terminator, quote != UInt8(ascii: "'"))
    }

    /// Matches `$name` or `${name}` at `at`, returning the name and the bytes consumed.
    static func parseVariable(_ t: ByteString, at index: Int) -> (name: String, length: Int)? {
        var i = index + 1
        guard i < t.count else { return nil }

        let braced = t[i] == UInt8(ascii: "{")
        if braced { i += 1 }

        let start = i
        while i < t.count, Bytes.isWordByte(t[i]) { i += 1 }
        guard i > start else { return nil }
        let name = Bytes.describe(Array(t[start ..< i]))

        if braced {
            guard i < t.count, t[i] == UInt8(ascii: "}") else { return nil }
            i += 1
        }
        return (name, i - index)
    }

    static func isBlank(_ line: ByteString) -> Bool {
        line.allSatisfy { Bytes.isSpace($0) }
    }

    static func isComment(_ line: ByteString) -> Bool {
        trimmed(line).first == UInt8(ascii: "#")
    }

    static func trimmed(_ line: ByteString) -> ByteString {
        var start = 0
        var end = line.count
        while start < end, Bytes.isSpace(line[start]) { start += 1 }
        while end > start, Bytes.isSpace(line[end - 1]) { end -= 1 }
        return Array(line[start ..< end])
    }
}
