import AppKit
import CowsayKit
import Foundation
import os.log

/// The settings window shared by both front ends: the saver presents it as its ScreenSaver
/// Options sheet, and `Cowsaver.app` presents it as an ordinary window.
///
/// The sheet writes `config.json`, the same configuration file loaded by both front ends.
/// It is built programmatically, so its layout remains alongside the controls it creates.
public final class ConfigurationSheet: NSObject {
    public private(set) var window: NSWindow!
    private var configuration: Configuration
    private let onSave: (Configuration) -> Void

    // Controls are internal so the round-trip test can drive them.
    var rotationField: NSTextField!
    var wrapField: NSTextField!
    var maxLinesField: NSTextField!
    var themePopup: NSPopUpButton!
    var stylePopup: NSPopUpButton!
    var fontSizeField: NSTextField!
    var adaptiveWrapBox: NSButton!
    var randomCowBox: NSButton!
    var repositionBox: NSButton!
    var sizeVariationBox: NSButton!
    var transitionBox: NSButton!
    var okButton: NSButton!
    /// One checkbox per bundled cow, in the order the list shows them.
    private(set) var cowfileBoxes: [NSButton] = []

    /// Shown when raw `foreground` and `background` values are active instead of a preset.
    private let customColoursTitle = "custom colours"

    /// The `sizeVariation` the controls were built from. Checking the box hands back a
    /// hand-edited value rather than replacing it with the amount below.
    private var loadedSizeVariation: Double = 0

    /// What checking the box means when the file names no amount of its own.
    private let defaultSizeVariation = 0.3

    public convenience init(configuration: Configuration,
                            onSave: @escaping (Configuration) -> Void) {
        self.init(configuration: configuration,
                  cowfileNames: Self.bundledCowfileNames(),
                  onSave: onSave)
    }

    /// The cow names are injectable so tests do not depend on a bundle being present, and
    /// the height cap so a test can describe a screen this machine does not have.
    init(configuration: Configuration,
         cowfileNames: [String],
         maximumContentHeight: CGFloat? = ConfigurationSheet.availableContentHeight(),
         onSave: @escaping (Configuration) -> Void) {
        self.configuration = configuration
        self.onSave = onSave
        super.init()
        buildWindow(cowfileNames: cowfileNames, maximumContentHeight: maximumContentHeight)
    }

    /// The tallest this window's content may be, or nil where there is no screen to ask.
    ///
    /// The saver's host presents this window as a sheet on the System Settings window, so
    /// the room it has is the visible frame less that window's own title bar and the inset a
    /// sheet keeps from the top of its parent. The margin is deliberately generous: a sheet
    /// whose buttons sit past the bottom of the screen cannot be dismissed (issue #16),
    /// while one that starts scrolling a little sooner than it strictly must costs nothing.
    /// On any display with room for the natural height, this changes nothing.
    static func availableContentHeight() -> CGFloat? {
        guard let visible = NSScreen.main?.visibleFrame else { return nil }
        return visible.height - 120
    }

    /// The bundled cow names, read from whichever bundle carries this class: the `.saver`
    /// under the screensaver host, `Cowsaver.app` in the standalone app.
    private static func bundledCowfileNames() -> [String] {
        let bundle = Bundle(for: ConfigurationSheet.self)
        let directories = ResourceLocations.cowDirectories(bundle: bundle)
        return CowfileLibrary.load(directories: directories).names
    }

    // MARK: Layout

    private func buildWindow(cowfileNames: [String], maximumContentHeight: CGFloat?) {
        let width: CGFloat = 420
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "Cowsaver"

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        // The bottom inset is what keeps the last control clear of the scroll view's edge:
        // the window is sized to this stack's fitting height, so a zero inset ends it
        // flush with the final button and clips its lower edge.
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        rotationField = NSTextField(string: "")
        wrapField = NSTextField(string: "")
        maxLinesField = NSTextField(string: "")
        fontSizeField = NSTextField(string: "")
        for field in [rotationField, wrapField, maxLinesField, fontSizeField] {
            field?.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }

        themePopup = NSPopUpButton()
        themePopup.addItems(withTitles: ThemePreset.all.map(\.name))
        themePopup.addItem(withTitle: customColoursTitle)

        stylePopup = NSPopUpButton()
        stylePopup.addItems(withTitles: ["say", "think"])

        adaptiveWrapBox = checkbox("Widen the balloon when that makes the text bigger", on: false)
        randomCowBox = checkbox("Random cow each rotation", on: false)
        repositionBox = checkbox("Move to a new position each rotation", on: false)
        sizeVariationBox = checkbox("Vary the text size between rotations", on: false)
        transitionBox = checkbox("Fade between fortunes", on: false)
        cowfileBoxes = cowfileNames.map { checkbox($0, on: false) }

        stack.addArrangedSubview(row("Seconds between fortunes:", rotationField))
        stack.addArrangedSubview(caption("""
            How long one fortune stays on screen before Cowsaver draws the next.
            """, width: width))
        stack.addArrangedSubview(row("Narrowest wrap column:", wrapField))
        stack.addArrangedSubview(row("Longest fortune, in lines (0 = no limit):", maxLinesField))
        stack.addArrangedSubview(row("Font size (0 = fit to screen):", fontSizeField))
        stack.addArrangedSubview(row("Theme:", themePopup))
        stack.addArrangedSubview(row("Balloon:", stylePopup))
        stack.addArrangedSubview(adaptiveWrapBox)
        stack.addArrangedSubview(randomCowBox)
        stack.addArrangedSubview(repositionBox)
        stack.addArrangedSubview(sizeVariationBox)
        stack.addArrangedSubview(transitionBox)

        let cowHeader = NSStackView(views: [
            NSTextField(labelWithString: "Cows:"),
            NSButton(title: "All", target: self, action: #selector(checkEveryCow)),
            NSButton(title: "None", target: self, action: #selector(uncheckEveryCow)),
        ])
        cowHeader.orientation = .horizontal
        cowHeader.spacing = 8
        stack.addArrangedSubview(cowHeader)
        stack.addArrangedSubview(cowfileList(width: width))
        stack.addArrangedSubview(caption("""
            Checking every cow, or none of them, saves an empty list, which Cowsaver reads \
            as the whole bundled set.
            """, width: width))

        // Show the configuration location shared by the sheet and the runtime loader.
        stack.addArrangedSubview(caption("""
            Every setting here also lives in config.json inside Cowsaver's container, \
            which is the supported way to configure it. See docs/configuration.md for the path.
            """, width: width))
        stack.addArrangedSubview(NSButton(title: "Reveal config.json in Finder",
                                          target: self, action: #selector(revealConfiguration)))

        let restore = NSButton(title: "Restore Defaults", target: self,
                               action: #selector(restoreDefaults))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        okButton = NSButton(title: "OK", target: self, action: #selector(save))
        okButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), restore, cancel, okButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        // The controls scroll; the buttons do not. A window capped shorter than its controls
        // still has to offer Restore Defaults, Cancel, and OK, or it cannot be dismissed.
        let scroll = scrollingDocument(stack)
        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -buttonGap),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                            constant: -buttonMargin),
        ])
        window.contentView = content
        apply(configuration)
        // Size from the arranged controls so adding a row expands the sheet automatically,
        // and cap that at the room the screen has: the same height as before wherever it
        // fits, and a scrolling document rather than unreachable buttons where it does not.
        content.layoutSubtreeIfNeeded()
        let natural = stack.fittingSize.height + buttons.fittingSize.height
            + buttonGap + buttonMargin
        window.setContentSize(NSSize(width: width,
                                     height: min(natural, maximumContentHeight ?? natural)))
        self.window = window
    }

    /// The gap above the button row, and the margin below it.
    private let buttonGap: CGFloat = 12
    private let buttonMargin: CGFloat = 20

    /// Everything above the button row, in a document that scrolls when the window is capped
    /// shorter than the controls are tall.
    ///
    /// `drawsBackground` is off so the window's own background still shows through; on a
    /// screen with room for the whole sheet, nothing about the sheet changes at all.
    private func scrollingDocument(_ stack: NSStackView) -> NSScrollView {
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    private func row(_ label: String, _ control: NSView) -> NSStackView {
        let text = NSTextField(labelWithString: label)
        let row = NSStackView(views: [text, control])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func checkbox(_ title: String, on: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = on ? .on : .off
        return button
    }

    /// A secondary line under the control it explains.
    private func caption(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width - 40
        return label
    }

    /// A scroll view's document view starts at the top only when it is flipped.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private func cowfileList(width: CGFloat) -> NSScrollView {
        let list = NSStackView(views: cowfileBoxes)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        list.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            // The names scroll: 47 cows must not make a sheet 47 rows tall.
            scroll.heightAnchor.constraint(equalToConstant: 150),
            scroll.widthAnchor.constraint(equalToConstant: width - 40),
        ])
        return scroll
    }

    // MARK: Controls and configuration

    /// Put a configuration into the controls. Nothing is written until OK.
    func apply(_ configuration: Configuration) {
        rotationField.stringValue = String(Int(configuration.rotationSeconds))
        wrapField.stringValue = String(configuration.wrapWidth)
        maxLinesField.stringValue = String(configuration.maxFortuneLines)
        fontSizeField.stringValue = String(Int(configuration.fontSize))

        if let theme = configuration.theme, ThemePreset.named(theme) != nil {
            themePopup.selectItem(withTitle: theme)
        } else {
            themePopup.selectItem(withTitle: customColoursTitle)
        }
        stylePopup.selectItem(withTitle: configuration.balloonStyle)

        adaptiveWrapBox.state = configuration.adaptiveWrap ? .on : .off
        randomCowBox.state = configuration.randomCow ? .on : .off
        repositionBox.state = configuration.reposition ? .on : .off
        sizeVariationBox.state = configuration.sizeVariation > 0 ? .on : .off
        loadedSizeVariation = configuration.sizeVariation
        transitionBox.state = configuration.wantsTransition ? .on : .off

        // An empty list means every bundled cow, which shows as all of them checked.
        let selected = Set(configuration.cowfiles)
        for box in cowfileBoxes {
            box.state = selected.isEmpty || selected.contains(box.title) ? .on : .off
        }
    }

    /// The checked names in list order. Everything checked — or nothing — saves an empty
    /// list, the engine's existing spelling for every bundled cow.
    private func selectedCowfiles() -> [String] {
        let checked = cowfileBoxes.filter { $0.state == .on }
        if checked.isEmpty || checked.count == cowfileBoxes.count { return [] }
        return checked.map(\.title)
    }

    // MARK: Actions

    @objc private func cancel() { close() }

    @objc func save() {
        // Read values independently; Configuration applies the same range checks as file loading.
        var updated = configuration
        if let value = Double(rotationField.stringValue) { updated.rotationSeconds = value }
        if let value = Int(wrapField.stringValue) { updated.wrapWidth = value }
        if let value = Int(maxLinesField.stringValue) { updated.maxFortuneLines = value }
        if let value = Double(fontSizeField.stringValue) { updated.fontSize = value }
        let selectedTheme = themePopup.titleOfSelectedItem
        updated.theme = selectedTheme == customColoursTitle ? nil : selectedTheme
        updated.balloonStyle = stylePopup.titleOfSelectedItem ?? "say"
        updated.adaptiveWrap = adaptiveWrapBox.state == .on
        updated.randomCow = randomCowBox.state == .on
        updated.reposition = repositionBox.state == .on
        updated.sizeVariation = sizeVariationBox.state == .on
            ? (loadedSizeVariation > 0 ? loadedSizeVariation : defaultSizeVariation)
            : 0
        updated.transition = transitionBox.state == .on ? "fade" : "none"
        updated.cowfiles = selectedCowfiles()

        configuration = updated
        onSave(updated)
        close()
    }

    @objc private func checkEveryCow() { setEveryCow(.on) }

    @objc private func uncheckEveryCow() { setEveryCow(.off) }

    private func setEveryCow(_ state: NSControl.StateValue) {
        for box in cowfileBoxes { box.state = state }
    }

    @objc private func restoreDefaults() {
        let alert = NSAlert()
        alert.messageText = "Restore the default settings?"
        alert.informativeText = """
            Every control in this window goes back to the value Cowsaver ships with. \
            Nothing is written to config.json until you click OK.
            """
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.apply(Configuration())
        }
    }

    @objc private func revealConfiguration() {
        let url = ResourceLocations.canonicalConfigurationURL()
        // A sandboxed host may refuse to hand the request to Finder, and there is nothing
        // useful to say about that in the window; the log line is the whole report.
        guard FileManager.default.fileExists(atPath: url.path) else {
            log("no config.json to reveal at \(url.path); click OK to write one")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func close() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            // End only a modal session this window owns. Stopping one it does not own would
            // interrupt whatever loop is actually running.
            if NSApp?.modalWindow === window { NSApp.stopModal() }
            window.orderOut(nil)
        }
    }

    private static let logger = Logger(subsystem: "com.matthewsundling.cowsaver", category: "sheet")

    private func log(_ message: String) {
        // os_log rather than NSLog: the macOS 26 host drops NSLog output from the appex,
        // and public privacy keeps the message readable in `log show`.
        Self.logger.log("[Cowsaver] \(message, privacy: .public)")
    }
}

// MARK: - Writing the config file

extension ConfigurationSheet {
    /// Write the settings back to `config.json`.
    ///
    /// `config.json` is the whole configuration, so the sheet writes it rather than a store
    /// of its own. It writes the canonical path, which is the copy both front ends read.
    /// `Configuration.jsonObject` centralizes the persisted schema and is covered by the
    /// configuration tests.
    public static func persist(_ configuration: Configuration) -> String? {
        let url = ResourceLocations.canonicalConfigurationURL()
        let directory = url.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: configuration.jsonObject,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return "could not write \(url.path): \(error.localizedDescription)"
        }
    }
}
