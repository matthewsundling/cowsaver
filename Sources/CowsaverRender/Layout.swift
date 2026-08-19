import AppKit
import CowsayKit

public struct LayoutMetrics: Equatable {
    public let fontSize: CGFloat
    public let textSize: CGSize
    public let columns: Int
    public let rows: Int
}

public enum Layout {
    /// Widest line and line count, in characters.
    ///
    /// Forwards to `AdaptiveWrap.gridSize`, which documents why display measurement counts
    /// characters while cowsay-compatible wrapping counts bytes.
    public static func measure(_ block: String) -> (columns: Int, rows: Int) {
        AdaptiveWrap.gridSize(of: block)
    }

    /// Describe `bounds` in the ratios `AdaptiveWrap` needs to pick a wrap width.
    ///
    /// Font metrics live in this layer, so the conversion does too. The margin `fit` applies
    /// is absent on purpose: it scales both dimensions equally and cancels out of a ratio.
    ///
    /// Nil when there is nothing meaningful to fit — a zero-sized view, or a font that
    /// reports no advance. Callers pass the nil straight through and get the configured
    /// wrap width, which is the right answer when the shape of the screen is unknown.
    public static func canvas(theme: Theme, in bounds: CGSize) -> AdaptiveWrap.Canvas? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let font = theme.font(ofSize: 100)
        let advance = characterWidth(of: font)
        let height = lineHeight(of: font)
        guard advance > 0, height > 0 else { return nil }
        return AdaptiveWrap.Canvas(aspectRatio: Double(bounds.width / bounds.height),
                                   cellAspectRatio: Double(advance / height))
    }

    /// The largest font size at which `block` fits inside `bounds` with a margin.
    ///
    /// There is no search loop. A monospaced font's advance width and line height scale
    /// linearly with point size, so one measurement at a reference size gives the exact
    /// ratio. That matters because this runs once per rotation on the main thread, and a
    /// binary search over `NSAttributedString.size()` would be both slower and no more
    /// accurate.
    public static func fit(
        block: String,
        theme: Theme,
        in bounds: CGSize,
        margin: CGFloat = 0.10,
        range: ClosedRange<CGFloat> = 6 ... 96
    ) -> LayoutMetrics {
        let (columns, rows) = measure(block)
        guard columns > 0, rows > 0, bounds.width > 0, bounds.height > 0 else {
            return LayoutMetrics(fontSize: range.lowerBound, textSize: .zero,
                                 columns: columns, rows: rows)
        }

        let reference: CGFloat = 100
        let font = theme.font(ofSize: reference)
        let advance = characterWidth(of: font)
        let lineHeight = self.lineHeight(of: font)
        guard advance > 0, lineHeight > 0 else {
            return LayoutMetrics(fontSize: range.lowerBound, textSize: .zero,
                                 columns: columns, rows: rows)
        }

        let available = CGSize(width: bounds.width * (1 - margin),
                               height: bounds.height * (1 - margin))
        let scale = min(available.width / (CGFloat(columns) * advance),
                        available.height / (CGFloat(rows) * lineHeight))

        let size = min(max(reference * scale, range.lowerBound), range.upperBound)
        let ratio = size / reference
        return LayoutMetrics(
            fontSize: size,
            textSize: CGSize(width: CGFloat(columns) * advance * ratio,
                             height: CGFloat(rows) * lineHeight * ratio),
            columns: columns,
            rows: rows
        )
    }

    /// Scale `metrics` down until the block fits `bounds`, ignoring the floor `fit` applies.
    ///
    /// Containment is the overriding invariant. At the 6 pt floor a worst-case block still
    /// overflows a Settings preview pane, and an oversized layer is what pins content at the
    /// origin and clips it (issue #3). The floor keeps its meaning as the preferred minimum
    /// wherever there is room for it; this pass engages only where the old path would have
    /// overflowed. `margin` matches `fit`'s so a contained block keeps the same breathing
    /// room as one that fitted normally.
    public static func contained(
        _ metrics: LayoutMetrics,
        in bounds: CGSize,
        margin: CGFloat = 0.10
    ) -> LayoutMetrics {
        let available = CGSize(width: bounds.width * (1 - margin),
                               height: bounds.height * (1 - margin))
        guard available.width > 0, available.height > 0,
              metrics.textSize.width > 0, metrics.textSize.height > 0 else { return metrics }
        guard metrics.textSize.width > available.width
                || metrics.textSize.height > available.height else { return metrics }

        let ratio = min(available.width / metrics.textSize.width,
                        available.height / metrics.textSize.height)
        // A font size of exactly zero asks AppKit for its *default* size, which would restore
        // the overflow this pass exists to remove. Only an underflow can reach that.
        guard metrics.fontSize * ratio > 0 else { return metrics }

        return LayoutMetrics(
            fontSize: metrics.fontSize * ratio,
            textSize: CGSize(width: metrics.textSize.width * ratio,
                             height: metrics.textSize.height * ratio),
            columns: metrics.columns,
            rows: metrics.rows
        )
    }

    /// Metrics for a size the user pinned explicitly (`fontSize` other than 0).
    public static func metrics(block: String, theme: Theme, fontSize: CGFloat) -> LayoutMetrics {
        let (columns, rows) = measure(block)
        let font = theme.font(ofSize: fontSize)
        return LayoutMetrics(
            fontSize: fontSize,
            textSize: CGSize(width: CGFloat(columns) * characterWidth(of: font),
                             height: CGFloat(rows) * lineHeight(of: font)),
            columns: columns,
            rows: rows
        )
    }

    static func characterWidth(of font: NSFont) -> CGFloat {
        // Fixed-pitch means every glyph has the same advance, so one probe is enough.
        let width = font.advancement(forGlyph: font.glyph(withName: "space")).width
        if width > 0 { return width }
        return NSAttributedString(string: "M", attributes: [.font: font]).size().width
    }

    static func lineHeight(of font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }
}
