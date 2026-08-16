import Foundation

/// Chooses the wrap width that lets a block be drawn as large as possible on a given screen.
///
/// cowsay's `-W` is a fixed preference. For an auto-fitting screensaver, the balloon and
/// animal share a character grid within a rectangular screen, so the useful width depends
/// on both the rendered block and the display shape.
///
/// The case that motivates it: a 2,000-character fortune wrapped at 40 columns is seventy
/// lines tall and gets shrunk hard to fit vertically. But the stegosaurus is 68 columns wide,
/// so the block is not width-limited by the balloon at all — every one of those lines bought
/// height for no width saving whatsoever. Wrapping the same fortune at 60 makes it much
/// shorter without making it wider than the animal, and the text comes out half again as big.
///
/// The renderer tries a small, fixed set of widths once per content rotation.
public enum AdaptiveWrap {
    /// The shape of the space a block has to fill, given as ratios rather than points so the
    /// decision can be made in Foundation-only code that has never heard of a screen.
    public struct Canvas: Equatable, Sendable {
        /// Drawable width ÷ height.
        public let aspectRatio: Double
        /// One character cell's width ÷ height in the render font. About 0.52 for Menlo.
        public let cellAspectRatio: Double

        public init(aspectRatio: Double, cellAspectRatio: Double) {
            self.aspectRatio = aspectRatio
            self.cellAspectRatio = cellAspectRatio
        }
    }

    /// A wider balloon is selected only when it improves the fitted font size by at least 10%.
    public static let widenThreshold = 1.10

    /// Widest line and line count, in characters.
    ///
    /// Counting characters rather than bytes is right here and wrong inside the renderer:
    /// cowsay wraps by byte, but a text layer draws glyphs. For the ASCII this project
    /// actually emits the two agree, and where they would not, the fortune filter has
    /// already removed the record.
    public static func gridSize(of block: String) -> (columns: Int, rows: Int) {
        var columns = 0
        var rows = 0
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            columns = max(columns, line.count)
            rows += 1
        }
        // A trailing newline should not count as a further row.
        if block.hasSuffix("\n") { rows = max(rows - 1, 0) }
        return (columns, rows)
    }

    /// How large this block can be drawn on this canvas, in arbitrary units.
    ///
    /// This is the same quantity `Layout.fit` computes in points, normalised to a canvas of
    /// height 1 — which is all a comparison between two candidates needs, and is why the
    /// margin does not appear: it scales both dimensions equally and cancels. The maths is
    /// stated twice, here and in the layer that owns font metrics, so `LayoutTests` asserts
    /// the two agree on ordering rather than trusting that they will not drift.
    public static func score(columns: Int, rows: Int, on canvas: Canvas) -> Double {
        guard columns > 0, rows > 0,
              canvas.aspectRatio > 0, canvas.cellAspectRatio > 0 else { return 0 }
        return min(canvas.aspectRatio / (Double(columns) * canvas.cellAspectRatio),
                   1 / Double(rows))
    }

    public static func score(of block: String, on canvas: Canvas) -> Double {
        let (columns, rows) = gridSize(of: block)
        return score(columns: columns, rows: rows, on: canvas)
    }

    /// Wrap widths to try, narrowest first.
    ///
    /// Candidate widths scale from the configured width. The first candidate is always that
    /// configured width, preserving fixed-width output when no wider choice clears the threshold.
    public static func candidates(base rawBase: Int) -> [Int] {
        let base = min(max(rawBase, 2), 500)
        let widths = [base, base * 3 / 2, base * 2, base * 5 / 2, base * 3]
        var seen: Set<Int> = []
        return widths.map { min($0, 500) }.filter { seen.insert($0).inserted }
    }
}
