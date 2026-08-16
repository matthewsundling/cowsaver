import Foundation

/// Cowsay-compatible byte strings.
///
/// cowsay 3.8.4 does not enable Perl's UTF-8 mode, so its lengths, slices, and wrapping
/// positions are byte-based. Cowsaver uses `ByteString` for the rendering core to preserve
/// those semantics. For example, cowsay can split a multi-byte character at a wrap boundary
/// and emit invalid UTF-8; this type allows the compatibility renderer to do the same.
public typealias ByteString = [UInt8]

public enum Bytes {
    public static let lf: UInt8 = 0x0A
    public static let space: UInt8 = 0x20
    public static let backslash: UInt8 = 0x5C
    public static let dollar: UInt8 = 0x24

    /// Perl's `\s`: space, tab, newline, vertical tab, form feed, carriage return.
    @inline(__always)
    public static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0B || b == 0x0C || b == 0x0D
    }

    @inline(__always)
    static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39) || b == 0x5F
    }

    public static func join(_ parts: [ByteString], separator: UInt8) -> ByteString {
        var out = ByteString()
        out.reserveCapacity(parts.reduce(0) { $0 + $1.count + 1 })
        for (i, p) in parts.enumerated() {
            if i > 0 { out.append(separator) }
            out.append(contentsOf: p)
        }
        return out
    }

    /// Split on a byte. Mirrors Perl's `split` with the default limit, which **drops
    /// trailing empty fields** — cowsay depends on this when it does
    /// `split("\n", fill(...))`.
    public static func split(_ s: ByteString, on sep: UInt8, dropTrailingEmpty: Bool = true) -> [ByteString] {
        var parts: [ByteString] = []
        var current = ByteString()
        for b in s {
            if b == sep {
                parts.append(current)
                current = []
            } else {
                current.append(b)
            }
        }
        parts.append(current)
        if dropTrailingEmpty {
            while let last = parts.last, last.isEmpty { parts.removeLast() }
        }
        return parts
    }

    /// Right-pad with spaces to `width`, reproducing Perl's `%-${width}s`.
    /// Never truncates: a string longer than `width` is returned unchanged, exactly as
    /// `sprintf` would.
    public static func padRight(_ s: ByteString, to width: Int) -> ByteString {
        guard s.count < width else { return s }
        return s + ByteString(repeating: space, count: width - s.count)
    }

    public static func repeated(_ b: UInt8, _ count: Int) -> ByteString {
        count > 0 ? ByteString(repeating: b, count: count) : []
    }

    public static func from(_ s: String) -> ByteString { Array(s.utf8) }

    /// Lossy on purpose — used only for diagnostics and error messages, never for output.
    public static func describe(_ s: ByteString) -> String {
        String(decoding: s, as: UTF8.self)
    }
}
