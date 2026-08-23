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
    /// The configuration OK last accepted: the starting point for the next save candidate,
    /// and what a failed save leaves untouched.
    private var configuration: Configuration
    /// Writes the candidate configuration. A test injects a deterministic stand-in; the real
    /// window uses `writeToDisk`.
    private let persister: (Configuration) -> SaveOutcome
    /// Called exactly once per successful save, after persistence has already succeeded.
    /// Never called for an invalid or unpersisted attempt.
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
    var restoreButton: NSButton!
    var cancelButton: NSButton!
    var okButton: NSButton!
    /// The inline save/validation error, shown near the fixed action buttons so it stays
    /// visible whether this window is hosted as a sheet or as the standalone app's window.
    var errorLabel: NSTextField!
    /// One checkbox per bundled cow, in the order the list shows them.
    private(set) var cowfileBoxes: [NSButton] = []

    /// Shown when raw `foreground` and `background` values are active instead of a preset.
    private let customColorsTitle = "custom colors"

    /// The `sizeVariation` the controls were built from. Checking the box hands back a
    /// hand-edited value rather than replacing it with the amount below.
    private var loadedSizeVariation: Double = 0

    /// What checking the box means when the file names no amount of its own.
    private let defaultSizeVariation = 0.3

    // MARK: Presentation sizing

    /// The height the controls actually need, recorded once when this window is built. Every
    /// later cap is measured against this, never against whatever height the window already
    /// has, so a taller display can restore it exactly and a shorter one always shrinks from
    /// the same baseline.
    private var naturalContentHeight: CGFloat = 0

    /// The screen a front end intends to present this window on, offered before it has an
    /// attached sheet parent or is itself visible. Once either of those exists it is the more
    /// authoritative source and this hint no longer matters, but it is kept rather than
    /// cleared: nothing depends on it being forgotten, and a `nil` parent/visible-window pair
    /// after presentation should fall back to it rather than to no cap at all.
    private var presentationScreenHint: NSScreen?

    public convenience init(configuration: Configuration,
                            onSave: @escaping (Configuration) -> Void) {
        self.init(configuration: configuration,
                  cowfileNames: Self.bundledCowfileNames(),
                  onSave: onSave)
    }

    /// The cow names are injectable so tests do not depend on a bundle being present, the
    /// height cap so a test can describe a screen this machine does not have, and the
    /// persister so a test can produce a deterministic write failure without touching a real
    /// user configuration or depending on file permissions.
    ///
    /// `maximumContentHeight` defaults to nil: construction never consults a screen, so the
    /// natural height it produces is the same regardless of which display eventually presents
    /// it. A front end supplies the real cap afterward, through `prepareForPresentation(on:)`.
    init(configuration: Configuration,
         cowfileNames: [String],
         maximumContentHeight: CGFloat? = nil,
         persister: @escaping (Configuration) -> SaveOutcome = ConfigurationSheet.writeToDisk,
         onSave: @escaping (Configuration) -> Void) {
        self.configuration = configuration
        self.persister = persister
        self.onSave = onSave
        super.init()
        buildWindow(cowfileNames: cowfileNames, maximumContentHeight: maximumContentHeight)
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
        themePopup.addItem(withTitle: customColorsTitle)

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

        restoreButton = NSButton(title: "Restore Defaults", target: self,
                                 action: #selector(restoreDefaults))
        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        okButton = NSButton(title: "OK", target: self, action: #selector(save))
        okButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), restoreButton, cancelButton, okButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        // Hidden until a save fails, so it costs no space in the common case: an NSStackView
        // collapses a hidden arranged view instead of reserving a blank line for it.
        errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.preferredMaxLayoutWidth = width - 40
        errorLabel.isHidden = true

        let bottomStack = NSStackView(views: [errorLabel, buttons])
        bottomStack.orientation = .vertical
        bottomStack.alignment = .leading
        bottomStack.spacing = 8
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            errorLabel.widthAnchor.constraint(equalTo: bottomStack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: bottomStack.widthAnchor),
        ])

        // The controls scroll; the bottom cluster does not. A window capped shorter than its
        // controls still has to offer Restore Defaults, Cancel, OK, and any error, or it
        // cannot be dismissed or explained.
        let scroll = scrollingDocument(stack)
        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(bottomStack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -buttonGap),
            bottomStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bottomStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bottomStack.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                                constant: -buttonMargin),
        ])
        window.contentView = content
        self.window = window
        window.delegate = self
        apply(configuration)
        // Size from the arranged controls so adding a row expands the sheet automatically,
        // and retain that as the natural height: a taller display can always return to it,
        // and a shorter one only ever caps it, never redefines it. A scrolling document,
        // not unreachable buttons, is what a cap shorter than this produces.
        content.layoutSubtreeIfNeeded()
        naturalContentHeight = stack.fittingSize.height + bottomStack.fittingSize.height
            + buttonGap + buttonMargin
        applyContentHeight(maximum: maximumContentHeight)
    }

    /// Prepares this window for presentation on `screen`, the front end's best guess at where
    /// it is about to appear. Call this exactly once, before the window is shown or handed to
    /// a host: `screen` only wins the sizing decision until an attached sheet parent or the
    /// window's own visibility supplies a more authoritative one (`applyHeightPolicy`), at
    /// which point becoming key or changing screens keeps the cap current on its own.
    public func prepareForPresentation(on screen: NSScreen?) {
        presentationScreenHint = screen
        applyHeightPolicy()
    }

    /// The room kept clear below the selected screen's visible frame, so a sheet's own lowest
    /// button never sits past the bottom of the display (issue #16).
    private static let screenAllowance: CGFloat = 120

    /// Parent wins once attached: `sheetParent` exists only after the host has actually begun
    /// the sheet relationship, and by then it names the real display in use. Before or without
    /// that, the window's own screen wins once the window is actually visible — an off-screen,
    /// not-yet-shown window's `screen` reflects where AppKit happened to place it at
    /// construction, not where a front end intends to present it. Before visibility, the
    /// initial hint is the best information a front end can offer; with none of the three,
    /// there is no cap at all.
    static func selectedMaximumContentHeight(parentVisibleHeight: CGFloat?,
                                              visibleWindowHeight: CGFloat?,
                                              hintVisibleHeight: CGFloat?) -> CGFloat? {
        let visible = parentVisibleHeight ?? visibleWindowHeight ?? hintVisibleHeight
        return visible.map { $0 - screenAllowance }
    }

    /// Reads every current candidate screen fresh — never a cached rectangle or height — and
    /// applies the resulting cap.
    private func applyHeightPolicy() {
        let maximum = Self.selectedMaximumContentHeight(
            parentVisibleHeight: window.sheetParent?.screen?.visibleFrame.height,
            visibleWindowHeight: window.isVisible ? window.screen?.visibleFrame.height : nil,
            hintVisibleHeight: presentationScreenHint?.visibleFrame.height)
        applyContentHeight(maximum: maximum)
    }

    /// Resizes to the lesser of the retained natural height and `maximum`, or back to the
    /// natural height when `maximum` is nil. Always measured from `naturalContentHeight`,
    /// never from the window's current (possibly already-reduced) height, so recapping is
    /// reversible in both directions rather than a one-way shrink.
    func applyContentHeight(maximum: CGFloat?) {
        let height = min(naturalContentHeight, maximum ?? naturalContentHeight)
        window.setContentSize(NSSize(width: window.frame.width, height: height))
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
    ///
    /// A configuration built directly in code, rather than loaded from a file, can hold a
    /// non-finite or extreme numeric value in any field. Each field is displayed through its
    /// defensive `effective...` value so this never traps and always shows a supported,
    /// in-range number.
    func apply(_ configuration: Configuration) {
        clearError()
        rotationField.stringValue = String(Int(configuration.rotationInterval))
        wrapField.stringValue = String(configuration.effectiveWrapWidth)
        maxLinesField.stringValue = String(configuration.effectiveMaxFortuneLines)
        fontSizeField.stringValue = fontSizeDisplayString(configuration.effectivePinnedFontSize)

        if let theme = configuration.theme, ThemePreset.named(theme) != nil {
            themePopup.selectItem(withTitle: theme)
        } else {
            themePopup.selectItem(withTitle: customColorsTitle)
        }
        stylePopup.selectItem(withTitle: configuration.balloonStyle)

        adaptiveWrapBox.state = configuration.adaptiveWrap ? .on : .off
        randomCowBox.state = configuration.randomCow ? .on : .off
        repositionBox.state = configuration.reposition ? .on : .off
        sizeVariationBox.state = configuration.effectiveSizeVariation > 0 ? .on : .off
        loadedSizeVariation = configuration.effectiveSizeVariation
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

    /// Validate every control, attempt to persist the result, and only then accept it.
    ///
    /// Order matters: nothing here mutates `configuration` (the sheet's accepted state)
    /// until persistence has actually succeeded, so a rejected value or a failed write
    /// leaves both the controls and the running front end exactly as they were.
    @objc func save() {
        var candidate = configuration

        guard let rotation = wholeNumber(rotationField.stringValue,
                                         in: Configuration.rotationSecondsRange) else {
            showValidationError(
                "Seconds between fortunes must be a whole number from "
                    + "\(Configuration.rotationSecondsRange.lowerBound) to "
                    + "\(Configuration.rotationSecondsRange.upperBound).",
                field: rotationField)
            return
        }
        candidate.rotationSeconds = Double(rotation)

        guard let wrap = wholeNumber(wrapField.stringValue,
                                     in: Configuration.wrapWidthRange) else {
            showValidationError(
                "Narrowest wrap column must be a whole number from "
                    + "\(Configuration.wrapWidthRange.lowerBound) to "
                    + "\(Configuration.wrapWidthRange.upperBound).",
                field: wrapField)
            return
        }
        candidate.wrapWidth = wrap

        guard let maxLines = wholeNumber(maxLinesField.stringValue,
                                         in: Configuration.maxFortuneLinesRange) else {
            showValidationError(
                "Longest fortune, in lines must be a whole number from "
                    + "\(Configuration.maxFortuneLinesRange.lowerBound) to "
                    + "\(Configuration.maxFortuneLinesRange.upperBound), or 0 for no limit.",
                field: maxLinesField)
            return
        }
        candidate.maxFortuneLines = maxLines

        guard let fontSize = fontSizeValue(fontSizeField.stringValue) else {
            showValidationError(
                "Font size must be 0 to fit the screen, or a number from "
                    + "\(Int(Configuration.pinnedFontSizeRange.lowerBound)) to "
                    + "\(Int(Configuration.pinnedFontSizeRange.upperBound)).",
                field: fontSizeField)
            return
        }
        candidate.fontSize = fontSize

        let selectedTheme = themePopup.titleOfSelectedItem
        candidate.theme = selectedTheme == customColorsTitle ? nil : selectedTheme
        candidate.balloonStyle = stylePopup.titleOfSelectedItem ?? "say"
        candidate.adaptiveWrap = adaptiveWrapBox.state == .on
        candidate.randomCow = randomCowBox.state == .on
        candidate.reposition = repositionBox.state == .on
        candidate.sizeVariation = sizeVariationBox.state == .on
            ? (loadedSizeVariation > 0 ? loadedSizeVariation : defaultSizeVariation)
            : 0
        candidate.transition = transitionBox.state == .on ? "fade" : "none"
        candidate.cowfiles = selectedCowfiles()

        switch persister(candidate) {
        case .saved:
            configuration = candidate
            clearError()
            onSave(candidate)
            close()
        case .failed(let reason):
            let path = ResourceLocations.canonicalConfigurationURL().path
            log("could not save settings to \(path): \(reason)")
            showSaveError("Cowsaver could not save \(path): \(reason)")
        }
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
        // A missing file has nothing for Finder to select. Keep the diagnostic log and tell
        // the person that OK is the action that creates the canonical configuration file.
        guard FileManager.default.fileExists(atPath: url.path) else {
            log("no config.json to reveal at \(url.path); click OK to write one")
            showSaveError("No config.json exists yet. Click OK to create it.")
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

    // MARK: Validation and error feedback

    /// Show a message and put the invalid field in front of the person, selected and ready
    /// to retype. Does not persist or accept anything.
    private func showValidationError(_ message: String, field: NSTextField) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        window.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// Show a save failure. The controls are left exactly as the person typed them.
    private func showSaveError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    /// A later successful save, or Restore Defaults, clears a message that no longer
    /// describes the controls.
    private func clearError() {
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
    }

    /// Rejects empty, non-numeric, non-finite, and fractional text instead of clamping it.
    /// Bounds are checked on the `Double` before any conversion to `Int`, so a huge or
    /// non-finite spelling is rejected rather than trapping the conversion: `range` is always
    /// one of Cowsaver's small documented ranges, well inside what `Int` can represent.
    private func wholeNumber(_ text: String, in range: ClosedRange<Int>) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let decoded = Double(trimmed), decoded.isFinite else { return nil }
        guard decoded.rounded(.towardZero) == decoded else { return nil }
        guard decoded >= Double(range.lowerBound), decoded <= Double(range.upperBound) else {
            return nil
        }
        return Int(decoded)
    }

    /// `fontSize` is the one numeric control that keeps its decimal value: `0` is exactly
    /// auto-fit, and every other valid value is returned unrounded so a typed or loaded
    /// `18.5` survives unchanged.
    private func fontSizeValue(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let decoded = Double(trimmed), decoded.isFinite else { return nil }
        if decoded == 0 { return 0 }
        guard decoded >= Configuration.pinnedFontSizeRange.lowerBound,
              decoded <= Configuration.pinnedFontSizeRange.upperBound else { return nil }
        return decoded
    }

    /// A whole value reads as a whole number; a pinned decimal such as `18.5` keeps its
    /// fraction instead of gaining floating-point noise.
    private func fontSizeDisplayString(_ value: Double) -> String {
        value.rounded(.towardZero) == value ? String(Int(value)) : String(value)
    }
}

// MARK: - Recapping on the window's own lifecycle

extension ConfigurationSheet: NSWindowDelegate {
    /// `sheetParent` exists only once the host has actually begun the sheet relationship,
    /// which happens after `configureSheet` has already returned; becoming key is the first
    /// moment that relationship is reliably in place, and it is also when the standalone
    /// window first has a real screen of its own.
    public func windowDidBecomeKey(_ notification: Notification) {
        applyHeightPolicy()
    }

    /// Moving to a shorter display must shrink the window; moving to a taller one must
    /// restore its natural height. Reapplying the same cap the window already has is
    /// harmless, so no attempt is made to detect or skip a same-size change.
    public func windowDidChangeScreen(_ notification: Notification) {
        applyHeightPolicy()
    }
}

// MARK: - Writing the config file

/// What came of one save attempt. Replaces the earlier `String?` convention, where `nil`
/// silently meant success and was easy to confuse with "no message yet".
enum SaveOutcome: Equatable, Sendable {
    case saved
    /// A human-readable reason, suitable for showing next to the OK button. The sheet adds
    /// the target path when it presents this to the person who clicked OK.
    case failed(String)
}

extension ConfigurationSheet {
    /// Write the settings back to `config.json`. The default persister; a test injects its
    /// own to produce a deterministic failure.
    ///
    /// `config.json` is the whole configuration, so this writes it rather than a store of its
    /// own. It writes the canonical path, which is the copy both front ends read.
    /// `Configuration.jsonObject` centralizes the persisted schema and is covered by the
    /// configuration tests.
    static func writeToDisk(_ configuration: Configuration) -> SaveOutcome {
        let url = ResourceLocations.canonicalConfigurationURL()
        let directory = url.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: configuration.jsonObject,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
