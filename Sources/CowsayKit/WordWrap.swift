import Foundation

/// cowsay-compatible word wrapping.
///
/// This reproduces what cowsay 3.8.4 actually does at `bin/cowsay` line 66:
///
/// ```perl
/// @message = ($opts{'n'} ? expand(@message)
///                        : split("\n", fill("", "", @message)));
/// ```
///
/// The following cowsay behaviors determine the implementation:
///
/// 1. **`-W 40` wraps at 39.** `Text::Wrap` computes its line length as
///    `$columns - length($indent) - 1`, reserving the final column.
/// 2. **`fill` reflows, it does not wrap line-by-line.** Runs of whitespace collapse to a
///    single space, so a tab becomes one space — *not* an 8-column tab stop. Tab stops
///    apply only on the `-n` path, which is `Text::Tabs::expand` and does no wrapping at
///    all.
/// 3. **Paragraphs split on a newline followed by whitespace**, not on blank lines as
///    such. So an *indented* line also starts a new paragraph. Paragraphs are rejoined
///    with a blank line, which survives into the balloon as an empty padded row.
public enum WordWrap {
    /// The `-n` path: expand tabs to 8-column stops, leave lines otherwise untouched.
    public static func expandTabs(_ lines: [ByteString], tabStop: Int = 8) -> [ByteString] {
        lines.map { line in
            var out = ByteString()
            var column = 0
            for b in line {
                if b == 0x09 {
                    let advance = tabStop - (column % tabStop)
                    out.append(contentsOf: Bytes.repeated(Bytes.space, advance))
                    column += advance
                } else {
                    out.append(b)
                    column += 1
                }
            }
            return out
        }
    }

    /// The default path: `split("\n", fill("", "", @message))`.
    ///
    /// `Text::Wrap` requires `$columns >= 2`. Cowsaver clamps smaller values to 2. This is
    /// an intentional divergence from cowsay's degenerate output for `-W 1`.
    public static func fill(_ lines: [ByteString], columns rawColumns: Int) -> [ByteString] {
        let columns = max(rawColumns, 2)
        let joined = Bytes.join(lines, separator: Bytes.lf)
        let paragraphs = splitParagraphs(joined)
        let wrapped = paragraphs.map { wrap(collapseWhitespace($0), columns: columns) }

        // Perl's `fill` rejoins paragraphs with "\n\n" because initial and subsequent
        // indent are equal (both ""), then cowsay splits the result on "\n".
        var all = ByteString()
        for (i, p) in wrapped.enumerated() {
            if i > 0 { all.append(Bytes.lf); all.append(Bytes.lf) }
            all.append(contentsOf: p)
        }
        return Bytes.split(all, on: Bytes.lf)
    }

    /// `split(/\n\s+/, ...)` — a newline followed by one or more whitespace bytes.
    static func splitParagraphs(_ s: ByteString) -> [ByteString] {
        var parts: [ByteString] = []
        var current = ByteString()
        var i = 0
        while i < s.count {
            if s[i] == Bytes.lf, i + 1 < s.count, Bytes.isSpace(s[i + 1]) {
                parts.append(current)
                current = []
                i += 1
                while i < s.count, Bytes.isSpace(s[i]) { i += 1 }   // \s+ is greedy
            } else {
                current.append(s[i])
                i += 1
            }
        }
        parts.append(current)
        while let last = parts.last, last.isEmpty { parts.removeLast() }
        return parts
    }

    /// `s/\s+/ /g` within a paragraph.
    static func collapseWhitespace(_ s: ByteString) -> ByteString {
        var out = ByteString()
        out.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            if Bytes.isSpace(s[i]) {
                out.append(Bytes.space)
                while i < s.count, Bytes.isSpace(s[i]) { i += 1 }
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return out
    }

    /// `Text::Wrap::wrap("", "", $paragraph)`, returning the result with embedded newlines.
    ///
    /// The Perl is a regex loop matching `\G([^\n]{0,$ll})($break|\n+|\z)`, which is
    /// greedy fill: take the longest prefix of at most `$ll` bytes that ends at a break.
    /// When no break exists within reach it falls through to `([^\n]{$ll})` — the
    /// `$huge = 'wrap'` default — and breaks a long word mid-way.
    static func wrap(_ text: ByteString, columns: Int) -> ByteString {
        let ll = max(columns - 1, 0)
        guard !text.isEmpty else { return [] }
        // A zero line length cannot make progress.
        guard ll > 0 else { return text }

        var lines: [ByteString] = []
        var start = 0
        while start < text.count {
            // Text::Wrap's loop guard, `while ($t !~ /\G(?:$break)*\Z/gc)`: once only
            // break characters remain, it stops — and those bytes are *dropped*, never
            // emitted. This is why a message of nothing but whitespace renders as an
            // empty balloon rather than a balloon containing a space.
            if text[start...].allSatisfy(Bytes.isSpace) { break }

            if text.count - start <= ll {
                lines.append(Array(text[start...]))
                break
            }
            // Largest k <= ll with a break at that offset (the regex backtracking).
            var breakAt = -1
            var k = ll
            while k >= 0 {
                if Bytes.isSpace(text[start + k]) { breakAt = k; break }
                k -= 1
            }
            if breakAt >= 0 {
                lines.append(Array(text[start ..< (start + breakAt)]))
                start += breakAt + 1        // the break byte itself is consumed
            } else {
                lines.append(Array(text[start ..< (start + ll)]))
                start += ll
            }
        }
        return Bytes.join(lines, separator: Bytes.lf)
    }
}
