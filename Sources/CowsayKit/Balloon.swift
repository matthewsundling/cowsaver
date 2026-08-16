import Foundation

/// Speech vs. thought. Selected in real cowsay by the program's own name
/// (`$0 =~ /think/i`), never by a flag — see the note on `FaceMode.tired`.
public enum BalloonMode: String, Sendable {
    case say, think
}

public struct Balloon {
    /// The finished balloon, top and bottom borders included.
    public let lines: [ByteString]
    /// The tail character the cow template's `$thoughts` expands to: `\` or `o`.
    public let thoughts: UInt8
}

public enum BalloonBuilder {
    /// Reproduces `construct_balloon`.
    ///
    /// Two orderings matter:
    ///
    /// - **Think mode is checked first**, before the line count. So `cowthink` uses `( )`
    ///   on *every* row, including the multi-line case — it never gets `/ \` corners.
    /// - **Single- vs. multi-line is decided after wrapping**, on the wrapped line count.
    ///   Exactly one line gets `< >`; two already get `/ \` and `\ /` with no `|` rows.
    ///
    /// Zero lines is a real case (empty input) and takes the `< >` branch with an empty
    /// body, giving `<  >`. cowsay reaches this by indexing `$message[0]` on an empty
    /// array and getting undef.
    public static func build(_ lines: [ByteString], mode: BalloonMode) -> Balloon {
        let width = lines.map(\.count).max() ?? 0
        let isSingle = lines.count < 2

        let thoughts: UInt8 = (mode == .think) ? UInt8(ascii: "o") : Bytes.backslash

        // up-left, up-right, down-left, down-right, left, right
        let border: [UInt8]
        if mode == .think {
            border = Array("()()()".utf8)
        } else if isSingle {
            border = Array("<>".utf8)
        } else {
            border = Array("/\\\\/||".utf8)
        }

        func row(_ left: UInt8, _ content: ByteString, _ right: UInt8) -> ByteString {
            // Perl's `sprintf("%s %-${max}s %s\n", ...)`. The padding is what puts real
            // trailing whitespace in cowsay's output; the golden tests compare it.
            [left, Bytes.space] + Bytes.padRight(content, to: width) + [Bytes.space, right]
        }

        var out: [ByteString] = []
        out.append([Bytes.space] + Bytes.repeated(UInt8(ascii: "_"), width + 2))
        out.append(row(border[0], lines.first ?? [], border[1]))
        if !isSingle {
            for line in lines[1 ..< (lines.count - 1)] {
                out.append(row(border[4], line, border[5]))
            }
            out.append(row(border[2], lines[lines.count - 1], border[3]))
        }
        out.append([Bytes.space] + Bytes.repeated(UInt8(ascii: "-"), width + 2))

        return Balloon(lines: out, thoughts: thoughts)
    }
}
