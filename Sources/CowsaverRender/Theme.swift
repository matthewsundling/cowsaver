import AppKit
import CowsayKit

/// Resolved colors and a font, ready to hand to a layer.
///
/// The parsing and the presets live in `CowsayKit` (`ThemeColor`, `ThemePreset`) so they can
/// be tested without a window server. This file is only the AppKit conversion.
public struct Theme {
    public let foreground: NSColor
    public let background: NSColor
    public let fontName: String

    public init(configuration: Configuration) {
        self.foreground = NSColor(configuration.resolvedForeground)
        self.background = NSColor(configuration.resolvedBackground)
        self.fontName = configuration.fontName
    }

    /// Resolve the configured font, falling back through a chain that cannot fail.
    ///
    /// Alignment is not decorative here — the balloon borders only line up in a monospaced
    /// face, so a proportional font would visibly break the drawing. If the configured
    /// name is missing or not fixed-pitch we walk a list of faces macOS has shipped for
    /// years, and end at `NSFont.monospacedSystemFont`, which is always available.
    public func font(ofSize size: CGFloat) -> NSFont {
        let candidates = [fontName, "Menlo", "SF Mono", "Monaco", "Courier New"]
        for name in candidates {
            if let font = NSFont(name: name, size: size), font.isFixedPitch {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

public extension NSColor {
    convenience init(_ color: ThemeColor) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }
}

