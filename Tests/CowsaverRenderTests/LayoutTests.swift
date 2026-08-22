import AppKit
import CowsayKit
import Foundation
import Testing
@testable import CowsaverRender

@Suite("Layout and theme")
struct LayoutTests {
    private var theme: Theme { Theme(configuration: Configuration()) }

    @Test func measuresColumnsAndRows() {
        #expect(Layout.measure("abc\nde\nf").columns == 3)
        #expect(Layout.measure("abc\nde\nf").rows == 3)
    }

    /// Rendered cow blocks always end with a newline; that must not count as a further row
    /// or every block would be laid out one line too tall.
    @Test func trailingNewlineIsNotAnExtraRow() {
        #expect(Layout.measure("one\ntwo\n").rows == 2)
    }

    @Test func emptyBlockDoesNotCrash() {
        let metrics = Layout.fit(block: "", theme: theme, in: CGSize(width: 800, height: 600))
        #expect(metrics.fontSize > 0)
    }

    @Test func zeroBoundsDoNotCrash() {
        let metrics = Layout.fit(block: "hello", theme: theme, in: .zero)
        #expect(metrics.fontSize > 0)
    }

    /// `AdaptiveWrap.score` mirrors this file's fit arithmetic in Foundation-only code, so
    /// adaptive wrapping can choose widths before AppKit measures a font. Keep the two
    /// calculations proportional.
    ///
    /// Dropping the margin and the reference size from `fit` leaves
    /// `fontSize = 100 · (1 - margin) · height / lineHeight · score`, which is a constant
    /// multiple of the score for a fixed canvas. Every case below stays inside the 6…96
    /// clamp, where that identity holds exactly.
    @Test func adaptiveWrapScoreIsProportionalToTheFittedFontSize() throws {
        let bounds = CGSize(width: 1440, height: 900)
        let canvas = try #require(Layout.canvas(theme: theme, in: bounds))

        var ratios: [Double] = []
        for (columns, rows) in [(40, 12), (68, 30), (100, 20), (120, 45), (55, 8)] {
            let block = Array(repeating: String(repeating: "x", count: columns), count: rows)
                .joined(separator: "\n")
            let metrics = Layout.fit(block: block, theme: theme, in: bounds)
            #expect(metrics.fontSize > 6 && metrics.fontSize < 96,
                    "\(columns)x\(rows) must land inside the clamp for this to mean anything")
            ratios.append(Double(metrics.fontSize)
                          / AdaptiveWrap.score(columns: columns, rows: rows, on: canvas))
        }

        let first = try #require(ratios.first)
        for ratio in ratios {
            #expect(abs(ratio - first) / first < 0.001,
                    "score and fit disagree: \(ratios)")
        }
    }

    /// On a 16:10 screen, a long 40-column fortune is often height-limited. A wider balloon
    /// can reduce rows without exceeding the animal's existing width.
    @Test func wrappingWiderMakesALongFortuneVisiblyBigger() throws {
        let bounds = CGSize(width: 1440, height: 900)
        let canvas = try #require(Layout.canvas(theme: theme, in: bounds))
        let long = String(repeating: "word ", count: 400)

        func block(at columns: Int) -> String {
            String(decoding: CowRenderer.render(message: long, cowfile: BuiltIn.defaultCow,
                                                wrapColumns: columns), as: UTF8.self)
        }

        let widths = AdaptiveWrap.candidates(base: 40)
        let chosen = try #require(widths.max {
            AdaptiveWrap.score(of: block(at: $0), on: canvas)
                < AdaptiveWrap.score(of: block(at: $1), on: canvas)
        })
        #expect(chosen > 40, "a 2,000-character fortune should not stay at 40 columns")

        let fixed = Layout.fit(block: block(at: 40), theme: theme, in: bounds)
        let adapted = Layout.fit(block: block(at: chosen), theme: theme, in: bounds)
        #expect(adapted.fontSize > fixed.fontSize * 1.1,
                "\(fixed.fontSize)pt at -W 40 vs \(adapted.fontSize)pt at -W \(chosen)")
    }

    /// Auto-fit uses a smaller font for a wider block in the same bounds.
    @Test func widerBlocksGetSmallerFonts() {
        let bounds = CGSize(width: 1440, height: 900)
        let narrow = Layout.fit(block: String(repeating: "x", count: 20),
                                theme: theme, in: bounds)
        let wide = Layout.fit(block: String(repeating: "x", count: 200),
                              theme: theme, in: bounds)
        #expect(wide.fontSize < narrow.fontSize)
    }

    @Test func tallerBlocksGetSmallerFonts() {
        let bounds = CGSize(width: 1440, height: 900)
        let short = Layout.fit(block: Array(repeating: "xx", count: 4).joined(separator: "\n"),
                               theme: theme, in: bounds)
        let tall = Layout.fit(block: Array(repeating: "xx", count: 80).joined(separator: "\n"),
                              theme: theme, in: bounds)
        #expect(tall.fontSize < short.fontSize)
    }

    @Test func respectsTheClampRange() {
        let bounds = CGSize(width: 1440, height: 900)
        let tiny = Layout.fit(block: "i", theme: theme, in: bounds, range: 6 ... 40)
        #expect(tiny.fontSize <= 40)

        let enormous = Layout.fit(block: String(repeating: "x", count: 100_000),
                                  theme: theme, in: bounds, range: 6 ... 96)
        #expect(enormous.fontSize >= 6)
    }

    /// A fortune longer than the screen must still be laid out rather than overflowing
    /// unboundedly.
    @Test func absurdlyLargeBlockStillFitsInsideTheMargin() {
        let bounds = CGSize(width: 1440, height: 900)
        let block = (0 ..< 400).map { _ in String(repeating: "x", count: 120) }
            .joined(separator: "\n")
        let metrics = Layout.fit(block: block, theme: theme, in: bounds)
        // At the clamp floor it may not fit; above the floor it must.
        if metrics.fontSize > 6 {
            #expect(metrics.textSize.width <= bounds.width)
            #expect(metrics.textSize.height <= bounds.height)
        }
    }

    @Test func explicitFontSizeIsHonoured() {
        let metrics = Layout.metrics(block: "hello\nthere", theme: theme, fontSize: 24)
        #expect(metrics.fontSize == 24)
        #expect(metrics.textSize.width > 0)
    }

    /// Pins the figure quoted on `AdaptiveWrap.Canvas.cellAspectRatio`. Auto-fit assumes a
    /// cell roughly half as wide as it is tall; a face that violated that would quietly
    /// change every fitted font size. Returns early where Menlo is absent — the fallback
    /// chain deliberately permits other faces.
    @Test func menloCellAspectRatioMatchesTheDocumentedValue() throws {
        guard NSFont(name: "Menlo", size: 100) != nil else { return }
        var configuration = Configuration()
        configuration.fontName = "Menlo"
        let canvas = try #require(Layout.canvas(theme: Theme(configuration: configuration),
                                                in: CGSize(width: 1440, height: 900)))
        #expect(abs(canvas.cellAspectRatio - 0.52) < 0.01,
                "Menlo cell aspect is \(canvas.cellAspectRatio)")
    }
}

@Suite("Theme")
struct ThemeTests {
    @Test func resolvesTheConfiguredFont() {
        var configuration = Configuration()
        configuration.fontName = "Menlo"
        let font = Theme(configuration: configuration).font(ofSize: 24)
        #expect(font.pointSize == 24)
        #expect(font.isFixedPitch)
    }

    @Test func missingConfiguredFontFallsBackToAFixedPitchFont() {
        var configuration = Configuration()
        configuration.fontName = "Cowsaver-No-Such-Font-Exists"
        let font = Theme(configuration: configuration).font(ofSize: 18)
        #expect(font.isFixedPitch)
        #expect(font.pointSize == 18)
    }

    /// Balloon borders only line up in a monospaced face, so a proportional configured
    /// face must never be honoured even though AppKit can resolve it.
    @Test func proportionalConfiguredFontFallsBackToAFixedPitchFont() throws {
        let proportional = try #require(NSFont(name: "Helvetica", size: 18))
        #expect(!proportional.isFixedPitch, "the test requires a known proportional system font")

        var configuration = Configuration()
        configuration.fontName = "Helvetica"
        let font = Theme(configuration: configuration).font(ofSize: 18)
        #expect(font.isFixedPitch)
        #expect(font.pointSize == 18)
    }

    @Test func appliesThemePresetColors() {
        var configuration = Configuration()
        configuration.theme = "amber"
        let theme = Theme(configuration: configuration)
        // Amber is #FFB000: full red, substantial green, no blue.
        #expect(theme.foreground.redComponent > 0.9)
        #expect(theme.foreground.blueComponent < 0.1)
    }
}
