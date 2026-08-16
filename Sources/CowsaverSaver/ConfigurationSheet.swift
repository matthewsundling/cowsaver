import AppKit
import CowsayKit
import CowsaverRender
import Foundation

/// The ScreenSaver Options sheet.
///
/// The sheet writes `config.json`, the same configuration file loaded by both front ends.
/// It is built programmatically, so its layout remains alongside the controls it creates.
final class ConfigurationSheet: NSObject {
    private(set) var window: NSWindow!
    private var configuration: Configuration
    private let onSave: (Configuration) -> Void

    private var rotationField: NSTextField!
    private var wrapField: NSTextField!
    private var maxLinesField: NSTextField!
    private var themePopup: NSPopUpButton!
    private var stylePopup: NSPopUpButton!
    private var fontSizeField: NSTextField!
    private var adaptiveWrapBox: NSButton!
    private var randomCowBox: NSButton!
    private var repositionBox: NSButton!
    private var transitionBox: NSButton!

    /// Shown when raw `foreground` and `background` values are active instead of a preset.
    private let customColoursTitle = "custom colours"

    init(configuration: Configuration, onSave: @escaping (Configuration) -> Void) {
        self.configuration = configuration
        self.onSave = onSave
        super.init()
        buildWindow()
    }

    // MARK: Layout

    private func buildWindow() {
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
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        rotationField = NSTextField(string: String(Int(configuration.rotationSeconds)))
        wrapField = NSTextField(string: String(configuration.wrapWidth))
        maxLinesField = NSTextField(string: String(configuration.maxFortuneLines))
        fontSizeField = NSTextField(string: String(Int(configuration.fontSize)))
        for field in [rotationField, wrapField, maxLinesField, fontSizeField] {
            field?.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }

        themePopup = NSPopUpButton()
        themePopup.addItems(withTitles: ThemePreset.all.map(\.name))
        themePopup.addItem(withTitle: customColoursTitle)
        if let theme = configuration.theme, ThemePreset.named(theme) != nil {
            themePopup.selectItem(withTitle: theme)
        } else {
            themePopup.selectItem(withTitle: customColoursTitle)
        }

        stylePopup = NSPopUpButton()
        stylePopup.addItems(withTitles: ["say", "think"])
        stylePopup.selectItem(withTitle: configuration.balloonStyle)

        adaptiveWrapBox = checkbox("Widen the balloon when that makes the text bigger",
                                   on: configuration.adaptiveWrap)
        randomCowBox = checkbox("Random cow each rotation", on: configuration.randomCow)
        repositionBox = checkbox("Move to a new position each rotation", on: configuration.reposition)
        transitionBox = checkbox("Fade between fortunes", on: configuration.wantsTransition)

        stack.addArrangedSubview(row("Seconds between fortunes:", rotationField))
        stack.addArrangedSubview(row("Narrowest wrap column:", wrapField))
        stack.addArrangedSubview(row("Longest fortune, in lines (0 = no limit):", maxLinesField))
        stack.addArrangedSubview(row("Font size (0 = fit to screen):", fontSizeField))
        stack.addArrangedSubview(row("Theme:", themePopup))
        stack.addArrangedSubview(row("Balloon:", stylePopup))
        stack.addArrangedSubview(adaptiveWrapBox)
        stack.addArrangedSubview(randomCowBox)
        stack.addArrangedSubview(repositionBox)
        stack.addArrangedSubview(transitionBox)

        // Show the configuration location shared by the sheet and the runtime loader.
        let note = NSTextField(wrappingLabelWithString: """
            Every setting here also lives in config.json inside Cowsaver's container, \
            which is the supported way to configure it. See the README for the path.
            """)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = width - 40
        stack.addArrangedSubview(note)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "OK", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        // Size from the arranged controls so adding a row expands the sheet automatically.
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: width, height: stack.fittingSize.height))
        self.window = window
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

    // MARK: Actions

    @objc private func cancel() { close() }

    @objc private func save() {
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
        updated.transition = transitionBox.state == .on ? "fade" : "none"

        configuration = updated
        onSave(updated)
        close()
    }

    private func close() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            NSApp.stopModal()
            window.orderOut(nil)
        }
    }
}

// MARK: - Writing the config file

extension ConfigurationSheet {
    /// Write the settings back to `config.json`.
    ///
    /// The file has the highest configuration priority, so the sheet writes `config.json`
    /// rather than a separate `ScreenSaverDefaults` representation. `Configuration.jsonObject`
    /// centralizes the persisted schema and is covered by the configuration tests.
    static func persist(_ configuration: Configuration) -> String? {
        guard let directory = ResourceLocations.supportDirectories().first else {
            return "no writable support directory"
        }
        let url = directory.appendingPathComponent("config.json")

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
