import AppKit
import CowsayKit
import QuartzCore
import os.log

/// The view that actually shows a cow. Shared by the `.saver` and the standalone app, so
/// neither of them contains any drawing code of its own.
///
/// This view has no application-owned render loop and no `draw(_:)` override. It hosts a
/// `CATextLayer`, updates it on a content rotation, and has no further drawing work until
/// the next update. WindowServer chooses how to composite the layer; Cowsaver does not
/// select a GPU or submit rendering commands itself.
///
/// Its rendering behavior follows the low-activity design in `docs/power.md`:
///
/// - **Rule 3, no GPU frameworks.** A `CATextLayer` is an AppKit/Core Animation layer, not
///   an application-managed GPU renderer. `make check` rejects imports of the excluded
///   frameworks so the rendering surface remains small and inspectable.
/// - **Rule 4, transitions are brief.** The crossfade is a single `CABasicAnimation` on
///   `opacity`, ~0.6s, once per rotation. Nothing animates position, and nothing animates
///   continuously.
/// - **Rule 5, reposition rather than drift.** Each rotation places the block at a new
///   random point inside a safe inset. It changes position only when content changes.
public final class CowsaverContentView: NSView {
    private let textLayer = CATextLayer()
    private var theme: Theme
    private var configuration: Configuration
    private var randomGenerator: SplitMix64
    /// The most recent block, so a resize can re-fit without asking for new content.
    private var currentBlock: String = ""
    /// The bounds the current frame was fitted to, so a geometry signal that moved nothing
    /// re-presents nothing.
    private var presentedBounds: CGSize?

    /// The metrics the last `present` used, and the frame it gave the text layer. Zero until
    /// something has been presented.
    ///
    /// `ImageRenderer` and the tests read what was drawn instead of computing it a second
    /// time. A second computation can agree with itself while the view does something else,
    /// which is the one thing an offscreen rendering test must not miss.
    public private(set) var presentedMetrics = LayoutMetrics(fontSize: 0, textSize: .zero,
                                                             columns: 0, rows: 0)
    public private(set) var presentedTextFrame: CGRect = .zero

    public init(frame: NSRect, configuration: Configuration, seed: UInt64) {
        self.configuration = configuration
        self.theme = Theme(configuration: configuration)
        self.randomGenerator = SplitMix64(seed: seed)
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = theme.background.cgColor

        textLayer.isWrapped = false
        textLayer.alignmentMode = .left
        textLayer.foregroundColor = theme.foreground.cgColor
        // Text is the only thing on screen; let it be crisp on Retina.
        textLayer.contentsScale = window?.backingScaleFactor ?? 2
        layer?.addSublayer(textLayer)
        applyDebugFrame()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var isOpaque: Bool { true }

    /// Recompute scale when the view joins a window; `window` is unavailable during init.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor { textLayer.contentsScale = scale }
    }

    public func apply(configuration: Configuration) {
        self.configuration = configuration
        self.theme = Theme(configuration: configuration)
        layer?.backgroundColor = theme.background.cgColor
        textLayer.foregroundColor = theme.foreground.cgColor
        applyDebugFrame()
        if !currentBlock.isEmpty { present(currentBlock, animated: false) }
    }

    /// A 1 px border on the view's own layer (bounds) and a contrasting one on the text
    /// layer.
    ///
    /// A screenshot can then tell a host-geometry bug from a layout bug. Off by
    /// default; when off, rendering is unchanged (`borderWidth` is already `0` on a fresh
    /// `CALayer`).
    ///
    /// Called from `init`, `apply(configuration:)`, and `present` so the borders persist
    /// across a config reload, a resize, and a rotation, whichever changes first.
    private func applyDebugFrame() {
        let width: CGFloat = configuration.debugFrame ? 1 : 0
        layer?.borderWidth = width
        layer?.borderColor = Self.debugBoundsColor
        textLayer.borderWidth = width
        textLayer.borderColor = Self.debugTextColor
    }

    private static let debugBoundsColor = NSColor.red.cgColor
    private static let debugTextColor = NSColor.blue.cgColor

    /// This view's shape, to hand to `CowsaverEngine.nextBlock(fitting:)`.
    ///
    /// The balloon is then wrapped for the screen it is about to appear on rather than for a
    /// fixed 40 columns.
    public var canvas: AdaptiveWrap.Canvas? {
        Layout.canvas(theme: theme, in: bounds.size)
    }

    /// Show a block of ASCII art. This is the only thing that ever causes drawing.
    public func present(_ block: String, animated: Bool) {
        currentBlock = block

        // An explicitly pinned size is an explicit choice, so only auto-fit is contained; a
        // pinned size that cannot fit is clipped inside its own layer instead. See `frame(for:)`.
        let metrics = configuration.fontSize > 0
            ? Layout.metrics(block: block, theme: theme,
                             fontSize: CGFloat(configuration.fontSize))
            : Layout.contained(Layout.fit(block: block, theme: theme, in: bounds.size),
                               in: bounds.size)

        let font = theme.font(ofSize: metrics.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1
        paragraph.lineBreakMode = .byClipping

        let attributed = NSAttributedString(string: block, attributes: [
            .font: font,
            .foregroundColor: theme.foreground,
            .paragraphStyle: paragraph,
        ])

        let textFrame = frame(for: metrics)

        // Update content and geometry without implicit animations; the optional fade below
        // is the only transition associated with a rotation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.string = attributed
        textLayer.frame = textFrame
        CATransaction.commit()
        applyDebugFrame()   // re-present must not lose the border set at init/apply

        presentedMetrics = metrics
        presentedTextFrame = textFrame
        presentedBounds = bounds.size

        if animated, configuration.wantsTransition {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.6
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            textLayer.add(fade, forKey: "cowsaver.fade")
        }

        log("present bounds=\(Self.format(bounds)) fontSize=\(Self.format(metrics.fontSize)) " +
            "textFrame=\(Self.format(textLayer.frame))")
    }

    /// A new random position inside a safe inset, or centred if repositioning is off.
    ///
    /// The size is clamped to the view. A layer larger than its bounds is what leaves the
    /// slack below at zero, pinning the block at the origin and clipping it at the top and
    /// right; clamped, an oversized block is centred and clips inside its own layer instead.
    /// Auto-fit has already been contained, so the clamp only bites on a pinned `fontSize`.
    private func frame(for metrics: LayoutMetrics) -> CGRect {
        let size = CGSize(width: min(metrics.textSize.width, bounds.width),
                          height: min(metrics.textSize.height, bounds.height))
        guard configuration.reposition else {
            return CGRect(x: (bounds.width - size.width) / 2,
                          y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        }

        let slackX = max(bounds.width - size.width, 0)
        let slackY = max(bounds.height - size.height, 0)
        // Keep it off the very edge even when the block nearly fills the screen.
        let inset: CGFloat = 0.1
        let x = slackX * (inset + (1 - 2 * inset) * unitRandom())
        let y = slackY * (inset + (1 - 2 * inset) * unitRandom())
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func unitRandom() -> CGFloat {
        CGFloat(Double.random(in: 0 ... 1, using: &randomGenerator))
    }

    /// Re-fit the current block when the view's geometry changes.
    public override func setFrameSize(_ newSize: NSSize) {
        let oldSize = bounds.size
        super.setFrameSize(newSize)
        log("setFrameSize old=\(Self.format(oldSize)) new=\(Self.format(newSize))")
        refitIfBoundsChanged()
    }

    /// Re-fit from the layout pass too.
    ///
    /// A host can attach this view at a placeholder size and settle its real geometry by a
    /// path that never calls `setFrameSize` — the leading hypothesis for the clipping on
    /// timer activation in issue #2. Every such path still runs a layout pass.
    public override func layout() {
        super.layout()
        refitIfBoundsChanged()
    }

    /// Re-fit and re-scale when the backing store changes.
    ///
    /// Moving between displays changes the scale the text layer rasterises at, and can arrive
    /// alongside new bounds. Both matter to a view whose entire content is text.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor { textLayer.contentsScale = scale }
        refitIfBoundsChanged()
    }

    /// Re-present the current block, but only where the geometry actually moved.
    ///
    /// `layout()` fires far more often than the bounds change, and re-presenting identical
    /// geometry would redraw and re-log for nothing.
    private func refitIfBoundsChanged() {
        guard !currentBlock.isEmpty, bounds.size != presentedBounds else { return }
        present(currentBlock, animated: false)
    }

    private static let logger = Logger(subsystem: "com.matthewsundling.cowsaver", category: "render")

    private func log(_ message: String) {
        // Mirrors CowsaverView.log(_:); kept local so CowsaverRender has no dependency on
        // CowsaverSaver for a one-line logging wrapper. os_log rather than NSLog because
        // the macOS 26 host drops NSLog output from the appex; public privacy so `log show`
        // does not redact the message.
        Self.logger.log("[Cowsaver] \(message, privacy: .public)")
    }

    private static func format(_ size: NSSize) -> String {
        "\(format(size.width))x\(format(size.height))"
    }

    private static func format(_ rect: CGRect) -> String {
        "\(format(rect.width))x\(format(rect.height))@\(format(rect.minX)),\(format(rect.minY))"
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%g", Double(value))
    }
}
