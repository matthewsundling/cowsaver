import AppKit
import CowsayKit
import Foundation
import Testing
@testable import CowsaverRender

/// The sheet is the only editor for `config.json`, and both front ends persist whatever it
/// hands back. These tests drive its controls the way a person would and check what arrives.
///
/// `.serialized` and `@MainActor` keep AppKit window and control construction on the main
/// thread while swift-testing runs the broader suite concurrently. The cow names are
/// injected, so the list under test does not depend on a bundle being present.
@Suite("Settings sheet", .serialized)
@MainActor
struct ConfigurationSheetTests {
    private let cowfileNames = ["default", "dragon", "elephant", "stegosaurus", "tux"]

    /// Holds what the successful-save consumer was handed, and how many times.
    private final class Saved {
        var configuration: Configuration?
        var callCount = 0
    }

    /// A deterministic stand-in for `ConfigurationSheet.writeToDisk`. Records every candidate
    /// it was asked to persist and returns the next scripted outcome (repeating the last one
    /// once the script runs out), so a test never touches a real `config.json`.
    private final class Persistence {
        private(set) var calls: [Configuration] = []
        private var outcomes: [SaveOutcome]

        init(_ outcomes: [SaveOutcome] = [.saved]) { self.outcomes = outcomes }

        func persist(_ configuration: Configuration) -> SaveOutcome {
            calls.append(configuration)
            return calls.count <= outcomes.count ? outcomes[calls.count - 1] : outcomes[outcomes.count - 1]
        }
    }

    private func makeSheet(_ configuration: Configuration = Configuration(),
                           persister: @escaping (Configuration) -> SaveOutcome = { _ in .saved },
                           saving saved: Saved) -> ConfigurationSheet {
        ConfigurationSheet(configuration: configuration, cowfileNames: cowfileNames,
                           persister: persister) {
            saved.configuration = $0
            saved.callCount += 1
        }
    }

    /// A sheet built for a screen of a stated size. `nil` is no cap at all: the height the
    /// controls ask for, which is what a screen with room to spare produces.
    private func makeSheet(cappedAt cap: CGFloat?,
                           persister: @escaping (Configuration) -> SaveOutcome = { _ in .saved }
    ) -> ConfigurationSheet {
        ConfigurationSheet(configuration: Configuration(), cowfileNames: cowfileNames,
                           maximumContentHeight: cap, persister: persister) { _ in }
    }

    @Test func buildsItsControlsFromTheConfiguration() {
        var configuration = Configuration()
        configuration.rotationSeconds = 12
        configuration.wrapWidth = 55
        configuration.theme = "amber"
        configuration.balloonStyle = "think"
        configuration.face = "tired"
        configuration.reposition = false
        configuration.cowfiles = ["dragon", "tux"]

        let sheet = makeSheet(configuration, saving: Saved())

        #expect(sheet.rotationField.stringValue == "12")
        #expect(sheet.themePopup.titleOfSelectedItem == "amber")
        #expect(sheet.stylePopup.titleOfSelectedItem == "think")
        #expect(sheet.facePopup.titleOfSelectedItem == "-t Tired (--)")
        #expect(sheet.repositionBox.state == .off)
        #expect(sheet.cowfileBoxes.filter { $0.state == .on }.map(\.title) == ["dragon", "tux"])
    }

    @Test func sectionsAreTitledAndOrderedWithCowControlsTogether() throws {
        let sheet = makeSheet(saving: Saved())
        #expect(sheet.sectionTitles.map(\.stringValue) == [
            "[Timing]", "[Cow Selection]", "[Appearance]", "[Placement and Sizing]",
            "[Configuration]",
        ])

        let arranged = sheet.settingsStack.arrangedSubviews
        for title in sheet.sectionTitles.dropFirst() {
            let titleIndex = try #require(arranged.firstIndex { $0 === title })
            #expect(sheet.settingsStack.customSpacing(after: arranged[titleIndex - 1]) == 20,
                    "later section headings have extra whitespace above them")
        }
        let randomIndex = try #require(arranged.firstIndex { $0 === sheet.randomCowBox })
        let cowHeaderIndex = try #require(arranged.firstIndex { $0 === sheet.cowSelectionHeader })
        #expect(cowHeaderIndex == randomIndex + 1,
                "All/None follows Random cow without unrelated controls in between")
    }

    @Test func eyesPopupListsTheExactCowsayModesInFlagOrder() {
        let sheet = makeSheet(saving: Saved())
        #expect(sheet.facePopup.itemTitles == [
            "Default (oo)",
            "-b Borg (==)",
            "-d Dead (xx, tongue U)",
            "-g Greedy ($$)",
            "-p Paranoid (@@)",
            "-s Stoned (**, tongue U)",
            "-t Tired (--)",
            "-w Wired (OO)",
            "-y Youthful (..)",
            "random",
        ])
    }

    @Test func removedFileOnlyControlsAreAbsent() throws {
        let sheet = makeSheet(saving: Saved())
        func strings(in view: NSView) -> [String] {
            let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
            return own + view.subviews.flatMap(strings)
        }
        let content = try #require(sheet.window.contentView)
        let labels = strings(in: content)
        #expect(!labels.contains { $0.contains("Narrowest wrap") })
        #expect(!labels.contains { $0.contains("Longest fortune") })
        #expect(!labels.contains { $0.contains("Font size (0") })
        #expect(!labels.contains("Custom eyes"))
        #expect(!labels.contains("Custom tongue"))
    }

    @Test func handsBackEveryControlValueOnOK() throws {
        let saved = Saved()
        let sheet = makeSheet(saving: saved)

        sheet.rotationField.stringValue = "20"
        sheet.themePopup.selectItem(withTitle: "paperwhite")
        sheet.stylePopup.selectItem(withTitle: "random")
        sheet.facePopup.selectItem(withTitle: "-d Dead (xx, tongue U)")
        sheet.adaptiveWrapBox.state = .off
        sheet.randomCowBox.state = .off
        sheet.repositionBox.state = .off
        sheet.sizeVariationBox.state = .on
        sheet.transitionBox.state = .off
        for box in sheet.cowfileBoxes {
            box.state = ["dragon", "tux"].contains(box.title) ? .on : .off
        }

        sheet.save()

        let result = try #require(saved.configuration)
        #expect(result.rotationSeconds == 20)
        #expect(result.theme == "paperwhite")
        #expect(result.balloonStyle == "random")
        #expect(result.face == "dead")
        #expect(!result.adaptiveWrap)
        #expect(!result.randomCow)
        #expect(!result.reposition)
        #expect(result.sizeVariation == 0.3, "checked, with no amount in the file to keep")
        #expect(result.transition == "none")
        #expect(result.cowfiles == ["dragon", "tux"], "checked names, in the order listed")
    }

    /// The box is a shorthand for an amount, and it must not overwrite one already chosen:
    /// `sizeVariation` is a number in the file, and only the file can express 0.75.
    @Test func checkedSizeVariationKeepsAHandEditedAmount() throws {
        var configuration = Configuration()
        configuration.sizeVariation = 0.75
        let saved = Saved()
        let sheet = makeSheet(configuration, saving: saved)

        #expect(sheet.sizeVariationBox.state == .on, "a nonzero amount shows as checked")
        sheet.save()

        #expect(try #require(saved.configuration).sizeVariation == 0.75)
    }

    @Test func uncheckedSizeVariationSavesZero() throws {
        var configuration = Configuration()
        configuration.sizeVariation = 0.75
        let saved = Saved()
        let sheet = makeSheet(configuration, saving: saved)

        sheet.sizeVariationBox.state = .off
        sheet.save()

        #expect(try #require(saved.configuration).sizeVariation == 0)
    }

    /// "All" and "None" are the same instruction, and it is the one the engine already
    /// understands: an empty list means every bundled cow.
    @Test func everyCowAndNoCowBothSaveAnEmptyList() throws {
        for state in [NSControl.StateValue.on, .off] {
            let saved = Saved()
            let sheet = makeSheet(saving: saved)
            for box in sheet.cowfileBoxes { box.state = state }

            sheet.save()

            #expect(try #require(saved.configuration).cowfiles.isEmpty)
        }
    }

    @Test func anEmptyListArrivesAsEveryCowChecked() {
        var configuration = Configuration()
        configuration.cowfiles = []

        let sheet = makeSheet(configuration, saving: Saved())

        #expect(sheet.cowfileBoxes.allSatisfy { $0.state == .on })
    }

    /// Restore Defaults edits the controls and nothing else; OK still does the persisting.
    @Test func restoringDefaultsPutsShippedValuesInTheControls() throws {
        var configuration = Configuration()
        configuration.rotationSeconds = 5
        configuration.theme = "amber"
        configuration.cowfiles = ["dragon"]
        let saved = Saved()
        let sheet = makeSheet(configuration, saving: saved)
        #expect(sheet.rotationField.stringValue == "5")

        sheet.apply(Configuration())
        sheet.save()

        let defaults = Configuration()
        let result = try #require(saved.configuration)
        #expect(result.rotationSeconds == defaults.rotationSeconds)
        #expect(result.theme == defaults.theme)
        #expect(result.randomCow == defaults.randomCow)
        #expect(result.cowfiles == ["default", "dragon", "stegosaurus", "tux"],
                "the default cows, in the order the list shows them")
    }

    /// A screen without room for the whole sheet gets a shorter window with its controls
    /// scrolling, not a window whose buttons sit past the bottom edge (issue #16). A later
    /// recap to a different short cap — what a screen change delivers in production — must
    /// keep the same guarantee, not just the initial construction-time value.
    @Test func aScreenTooShortForTheSheetCapsItAndKeepsTheButtonsInside() throws {
        let cap: CGFloat = 500
        let sheet = makeSheet(cappedAt: cap)
        let content = try #require(sheet.window.contentView)
        content.layoutSubtreeIfNeeded()

        #expect(content.frame.height <= cap, "\(content.frame.height) is taller than the screen")
        let ok = sheet.okButton.convert(sheet.okButton.bounds, to: content)
        #expect(content.bounds.contains(ok),
                "OK at \(ok) is outside the window's \(content.bounds)")

        let recap = cap - 50
        sheet.applyContentHeight(maximum: recap)
        content.layoutSubtreeIfNeeded()

        #expect(content.frame.height <= recap,
                "\(content.frame.height) is taller than the recapped screen")
        let recappedOK = sheet.okButton.convert(sheet.okButton.bounds, to: content)
        #expect(content.bounds.contains(recappedOK),
                "OK at \(recappedOK) is outside the recapped window's \(content.bounds)")
    }

    /// The error footer grows the fixed bottom cluster, not the window: a save failure must
    /// not push the button row (or the message itself) past the same short-screen cap, and a
    /// later recap — a screen change while the error is still showing — must not either.
    @Test func aVisibleErrorFooterUnderTheShortScreenCapStaysInsideTheWindow() throws {
        let cap: CGFloat = 500
        let persistence = Persistence([.failed("permission denied")])
        let sheet = makeSheet(cappedAt: cap, persister: persistence.persist)

        sheet.save()   // the sheet's default values are valid; the injected persister fails
        #expect(!sheet.errorLabel.isHidden, "the failure must be visible before measuring layout")

        let content = try #require(sheet.window.contentView)
        content.layoutSubtreeIfNeeded()

        let controls: [NSView] = [sheet.errorLabel, sheet.restoreButton, sheet.cancelButton,
                                  sheet.okButton]
        func assertControlsAreInside(_ cap: CGFloat, why: String) {
            #expect(content.frame.height <= cap,
                    "\(why): \(content.frame.height) is taller than the screen")
            for control in controls {
                let frame = control.convert(control.bounds, to: content)
                #expect(content.bounds.contains(frame),
                        "\(why): \(control) at \(frame) is outside the window's \(content.bounds)")
            }
        }
        assertControlsAreInside(cap, why: "at construction")

        let recap = cap - 50
        sheet.applyContentHeight(maximum: recap)
        content.layoutSubtreeIfNeeded()
        assertControlsAreInside(recap, why: "after recapping with the error still visible")
    }

    /// The cap is a limit, not a size: with room to spare the window is exactly as tall as
    /// its controls, which is what every screen large enough already showed.
    @Test func aScreenWithRoomToSpareLeavesTheHeightAlone() throws {
        let capped = try #require(makeSheet(cappedAt: 2000).window.contentView)
        let natural = try #require(makeSheet(cappedAt: nil).window.contentView)

        #expect(capped.frame.height == natural.frame.height)
        #expect(natural.frame.height > 500,
                "the cap above only means something if 500 actually clamps")
    }

    // MARK: - Presentation sizing lifecycle

    /// `selectedMaximumContentHeight` is the pure precedence seam recapping is built on: an
    /// attached parent outranks the sheet's own visible screen, which outranks the initial
    /// front-end hint, which outranks having no cap at all. Numeric heights stand in for
    /// screens so this needs no real display and no fake `NSScreen`.
    @Test func selectionPrecedenceFavoursParentThenVisibleWindowThenTheInitialHint() {
        let allowance: CGFloat = 120

        let parentWins = ConfigurationSheet.selectedMaximumContentHeight(
            parentVisibleHeight: 900, visibleWindowHeight: 800, hintVisibleHeight: 700)
        #expect(parentWins == 900 - allowance,
                "an attached parent wins over everything else, less the 120-point allowance")

        let visibleWindowWins = ConfigurationSheet.selectedMaximumContentHeight(
            parentVisibleHeight: nil, visibleWindowHeight: 800, hintVisibleHeight: 700)
        #expect(visibleWindowWins == 800 - allowance,
                "without a parent, the sheet's own visible window wins over the initial hint")

        let hintWins = ConfigurationSheet.selectedMaximumContentHeight(
            parentVisibleHeight: nil, visibleWindowHeight: nil, hintVisibleHeight: 700)
        #expect(hintWins == 700 - allowance, "before either exists, the initial presentation hint wins")

        let noCap = ConfigurationSheet.selectedMaximumContentHeight(
            parentVisibleHeight: nil, visibleWindowHeight: nil, hintVisibleHeight: nil)
        #expect(noCap == nil, "with no candidate screen at all there is no cap, not zero and not a guess")
    }

    /// A short cap shrinks the window; a later, taller maximum must restore exactly the
    /// natural height recorded at construction, not merely grow from the reduced height.
    @Test func aShortCapThenATallMaximumShrinksThenRestoresExactlyTheNaturalHeight() throws {
        let sheet = makeSheet(cappedAt: nil)
        let content = try #require(sheet.window.contentView)
        content.layoutSubtreeIfNeeded()
        let natural = content.frame.height

        sheet.applyContentHeight(maximum: 400)
        content.layoutSubtreeIfNeeded()
        #expect(content.frame.height == 400, "a maximum below natural height caps it exactly")

        sheet.applyContentHeight(maximum: 5000)
        content.layoutSubtreeIfNeeded()
        #expect(content.frame.height == natural,
                "a maximum above natural height restores it exactly, not the reduced height")
    }

    /// Recapping is reversible in both directions: a tall maximum leaves the natural height
    /// alone, and a later, shorter one still shrinks it — proving this is always
    /// `min(naturalHeight, maximum)`, not a one-way `min` against whatever height the window
    /// was already reduced to.
    @Test func recappingShrinksAgainRatherThanStayingAtAnEarlierReducedHeight() throws {
        let sheet = makeSheet(cappedAt: nil)
        let content = try #require(sheet.window.contentView)
        content.layoutSubtreeIfNeeded()
        let natural = content.frame.height

        sheet.applyContentHeight(maximum: 5000)
        content.layoutSubtreeIfNeeded()
        #expect(content.frame.height == natural, "a maximum with room to spare changes nothing")

        sheet.applyContentHeight(maximum: 400)
        content.layoutSubtreeIfNeeded()
        #expect(content.frame.height == 400)

        sheet.applyContentHeight(maximum: 300)
        content.layoutSubtreeIfNeeded()
        #expect(content.frame.height == 300,
                "a still shorter maximum keeps shrinking rather than sticking at 400")
    }

    // MARK: - Save transaction

    @Test func successfulSavePersistsOnceAcceptsTheCandidateAndCallsTheConsumerOnce() throws {
        let persistence = Persistence()
        let saved = Saved()
        let sheet = makeSheet(persister: persistence.persist, saving: saved)
        sheet.rotationField.stringValue = "30"

        sheet.save()

        #expect(persistence.calls.count == 1, "persists exactly once")
        #expect(persistence.calls.first?.rotationSeconds == 30, "the complete candidate")
        #expect(saved.callCount == 1, "the consumer runs exactly once")
        #expect(try #require(saved.configuration).rotationSeconds == 30)
    }

    @Test func aDeterministicWriteFailureKeepsEveryEditAndExposesAHumanReadableError() throws {
        let persistence = Persistence([.failed("permission denied")])
        let saved = Saved()
        let sheet = makeSheet(persister: persistence.persist, saving: saved)
        sheet.rotationField.stringValue = "99"
        sheet.facePopup.selectItem(withTitle: "-w Wired (OO)")

        sheet.save()

        #expect(persistence.calls.count == 1, "one attempt")
        #expect(saved.callCount == 0, "the consumer never runs on a failed write")
        #expect(saved.configuration == nil, "the candidate is not accepted")
        #expect(sheet.rotationField.stringValue == "99", "every edited value is retained")
        #expect(sheet.facePopup.titleOfSelectedItem == "-w Wired (OO)")
        #expect(!sheet.errorLabel.isHidden, "the failure is visible")
        #expect(sheet.errorLabel.stringValue.contains("could not save"))
        #expect(sheet.errorLabel.stringValue.contains("config.json"))
        #expect(sheet.errorLabel.stringValue.contains("permission denied"),
                "the underlying reason, not an implementation dump")
    }

    @Test func aFailedAttemptFollowedByASuccessfulRetryPreservesEditsAndSucceedsOnce() throws {
        let persistence = Persistence([.failed("disk full"), .saved])
        let saved = Saved()
        let sheet = makeSheet(persister: persistence.persist, saving: saved)
        sheet.rotationField.stringValue = "99"

        sheet.save()
        #expect(sheet.rotationField.stringValue == "99", "the first attempt's edit survives")
        #expect(!sheet.errorLabel.isHidden)

        sheet.save()

        #expect(persistence.calls.count == 2, "the persister runs once per attempt")
        #expect(persistence.calls.allSatisfy { $0.rotationSeconds == 99 },
                "the retry still carries the values left in the controls")
        #expect(saved.callCount == 1, "only the successful attempt reaches the consumer")
        #expect(try #require(saved.configuration).rotationSeconds == 99)
        #expect(sheet.errorLabel.isHidden, "a later successful save clears the earlier error")
    }

    @Test func cancelPersistsNothingAndCallsNoConsumer() {
        let persistence = Persistence()
        let saved = Saved()
        let sheet = makeSheet(persister: persistence.persist, saving: saved)
        sheet.rotationField.stringValue = "99"

        _ = sheet.perform(NSSelectorFromString("cancel"))

        #expect(persistence.calls.isEmpty)
        #expect(saved.callCount == 0)
        #expect(saved.configuration == nil)
    }

    // MARK: - Numeric validation

    /// Sets an unrelated control before the invalid attempt, so the assertions below also
    /// prove an invalid value in one field never touches another.
    private func assertRejects(_ field: KeyPath<ConfigurationSheet, NSTextField?>,
                               text: String, why: String, messageContains fragment: String) {
        let persistence = Persistence()
        let saved = Saved()
        let sheet = makeSheet(persister: persistence.persist, saving: saved)
        sheet.randomCowBox.state = .off
        let target = sheet[keyPath: field]!
        target.stringValue = text

        sheet.save()

        #expect(persistence.calls.isEmpty, "\(why): must not persist")
        #expect(saved.callCount == 0, "\(why): must not call the consumer")
        #expect(saved.configuration == nil, "\(why): must not accept the candidate")
        #expect(target.stringValue == text, "\(why): the invalid text must be preserved exactly")
        #expect(sheet.randomCowBox.state == .off, "\(why): an unrelated control must not change")
        #expect(!sheet.errorLabel.isHidden, "\(why): the error must be visible")
        #expect(sheet.errorLabel.stringValue.contains(fragment),
                "\(why): message should name the field: \(sheet.errorLabel.stringValue)")
        #expect(target.currentEditor() != nil, "\(why): the invalid field should be focused")
    }

    @Test("Seconds between fortunes rejects invalid input", arguments: [
        ("0", "one below the lower bound"),
        ("601", "one above the upper bound"),
        ("45.5", "a fraction"),
        ("banana", "non-numeric text"),
        ("", "empty text"),
        ("   ", "whitespace-only text"),
        ("nan", "NaN"),
        ("inf", "positive infinity"),
        ("-inf", "negative infinity"),
        ("1e300", "a huge positive value"),
        ("-1e300", "a huge negative value"),
    ])
    func rotationSecondsRejectsInvalidInput(text: String, why: String) {
        assertRejects(\.rotationField, text: text, why: why,
                      messageContains: "Seconds between fortunes")
    }

    @Test func rotationSecondsAcceptsItsBoundariesAndWholeDecimalSpellings() throws {
        for (text, expected) in [("1", 1.0), ("600", 600.0), ("45.0", 45.0)] {
            let saved = Saved()
            let sheet = makeSheet(saving: saved)
            sheet.rotationField.stringValue = text

            sheet.save()

            #expect(try #require(saved.configuration).rotationSeconds == expected,
                    "\(text) should be accepted")
        }
    }

    // MARK: - Round trip and existing meanings

    @Test func customColorControlsTrackThemeVisibilityAndPreserveTypedSpelling() throws {
        let saved = Saved()
        let sheet = makeSheet(saving: saved)
        #expect(sheet.customColorRows.allSatisfy { $0.isHidden },
                "a named theme hides raw colors")

        sheet.themePopup.selectItem(withTitle: "custom colors")
        sheet.themeChanged()
        #expect(sheet.customColorRows.allSatisfy { !$0.isHidden })
        sheet.foregroundField.stringValue = "aBc"
        sheet.backgroundField.stringValue = "123456"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                object: sheet.foregroundField))
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                object: sheet.backgroundField))
        sheet.save()

        let result = try #require(saved.configuration)
        #expect(result.theme == nil)
        #expect(result.foreground == "aBc")
        #expect(result.background == "123456")
    }

    @Test func invalidVisibleCustomColorBlocksSaveAndFocusesItsField() {
        let persistence = Persistence()
        let sheet = makeSheet(persister: persistence.persist, saving: Saved())
        sheet.themePopup.selectItem(withTitle: "custom colors")
        sheet.themeChanged()
        sheet.foregroundField.stringValue = "not a color"

        sheet.save()

        #expect(persistence.calls.isEmpty)
        #expect(sheet.errorLabel.stringValue.contains("Foreground"))
        #expect(sheet.foregroundField.currentEditor() != nil)
    }

    @Test func namedThemeKeepsValidCustomDraftsButIgnoresInvalidHiddenOnes() throws {
        var configuration = Configuration()
        configuration.foreground = "#123456"
        configuration.background = "#654321"
        let saved = Saved()
        let sheet = makeSheet(configuration, saving: saved)
        sheet.foregroundField.stringValue = "invalid"
        sheet.backgroundField.stringValue = "AbC"
        sheet.themePopup.selectItem(withTitle: "amber")
        sheet.themeChanged()

        sheet.save()

        let result = try #require(saved.configuration)
        #expect(result.theme == "amber")
        #expect(result.foreground == "#123456", "a hidden invalid draft never persists")
        #expect(result.background == "AbC", "a valid custom draft remains available")
    }

    @Test func colorWellWritesOpaqueUppercaseSixDigitHexAndUpdatesPreview() {
        let sheet = makeSheet(saving: Saved())
        sheet.themePopup.selectItem(withTitle: "custom colors")
        sheet.themeChanged()
        sheet.foregroundWell.color = NSColor(srgbRed: 26.0 / 255.0, green: 128.0 / 255.0,
                                             blue: 1, alpha: 0.25)
        sheet.colorWellChanged(sheet.foregroundWell)

        #expect(sheet.foregroundField.stringValue == "#1A80FF")
        #expect(abs(sheet.previewField.textColor!.redComponent - 26.0 / 255.0) < 0.001)
    }

    @Test func typedColorsSynchronizeTheirWells() {
        let sheet = makeSheet(saving: Saved())
        sheet.foregroundField.stringValue = "#369"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                object: sheet.foregroundField))

        let color = sheet.foregroundWell.color.usingColorSpace(.sRGB)!
        #expect(abs(color.redComponent - 0.2) < 0.001)
        #expect(abs(color.greenComponent - 0.4) < 0.001)
        #expect(abs(color.blueComponent - 0.6) < 0.001)
    }

    @Test func everyStandardFaceChoiceSavesItsCanonicalName() throws {
        let choices = [
            ("Default (oo)", "default"),
            ("-b Borg (==)", "borg"),
            ("-d Dead (xx, tongue U)", "dead"),
            ("-g Greedy ($$)", "greedy"),
            ("-p Paranoid (@@)", "paranoid"),
            ("-s Stoned (**, tongue U)", "stoned"),
            ("-t Tired (--)", "tired"),
            ("-w Wired (OO)", "wired"),
            ("-y Youthful (..)", "young"),
        ]

        for (title, expected) in choices {
            var configuration = Configuration()
            configuration.face = expected == "default" ? "dead" : "default"
            let saved = Saved()
            let sheet = makeSheet(configuration, saving: saved)
            sheet.facePopup.selectItem(withTitle: title)
            sheet.save()
            #expect(try #require(saved.configuration).face == expected)
        }
    }

    @Test func cowPreviewUpdatesForSelectedEyesAndDerivedTongue() {
        let sheet = makeSheet(saving: Saved())
        sheet.facePopup.selectItem(withTitle: "-d Dead (xx, tongue U)")
        sheet.faceChanged()
        #expect(sheet.previewField.stringValue.contains("(xx)"))
        #expect(sheet.previewField.stringValue.contains(" U  ||----w |"))

        sheet.facePopup.selectItem(withTitle: "-w Wired (OO)")
        sheet.faceChanged()
        #expect(sheet.previewField.stringValue.contains("(OO)"))
        #expect(!sheet.previewField.stringValue.contains(" U  ||----w |"),
                "non-Dead and non-Stoned modes use cowsay's blank tongue")
    }

    @Test func randomFacePopupRoundTripsAndKeepsItsPreviewSampleDuringAppearanceEdits() throws {
        let saved = Saved()
        let sheet = makeSheet(saving: saved)
        sheet.facePopup.selectItem(withTitle: "random")
        sheet.faceChanged()

        let preview = sheet.previewField.stringValue
        let matchingEyes = ["oo", "==", "xx", "$$", "@@", "**", "--", "OO", ".."]
            .filter { preview.contains("(\($0))") }
        #expect(matchingEyes.count == 1, "Random preview must show one whole cowsay face")
        if let eyes = matchingEyes.first, ["xx", "**"].contains(eyes) {
            #expect(preview.contains(" U  ||----w |"))
        } else {
            #expect(!preview.contains(" U  ||----w |"))
        }

        sheet.themePopup.selectItem(withTitle: "amber")
        sheet.themeChanged()
        #expect(sheet.previewField.stringValue == preview,
                "theme and color edits retain Random's current preview sample")

        sheet.save()
        #expect(try #require(saved.configuration).face == "random")

        var reopenedConfiguration = Configuration()
        reopenedConfiguration.face = "random"
        let reopened = makeSheet(reopenedConfiguration, saving: Saved())
        #expect(reopened.facePopup.titleOfSelectedItem == "random")
    }

    @Test func fileFaceSpellingsAndCombinationsSurviveUntilTheChoiceChanges() throws {
        var abbreviated = Configuration()
        abbreviated.face = "d"
        let abbreviatedSave = Saved()
        let abbreviatedSheet = makeSheet(abbreviated, saving: abbreviatedSave)
        #expect(abbreviatedSheet.facePopup.titleOfSelectedItem == "-d Dead (xx, tongue U)")
        abbreviatedSheet.save()
        #expect(try #require(abbreviatedSave.configuration).face == "d")

        var combined = Configuration()
        combined.face = "dead, young"
        let preserved = Saved()
        let combinedSheet = makeSheet(combined, saving: preserved)
        #expect(combinedSheet.facePopup.titleOfSelectedItem ==
                "File-configured combination: dead, young")
        #expect(Array(combinedSheet.facePopup.itemTitles.suffix(2)) == [
            "File-configured combination: dead, young", "random",
        ], "Random remains the bottom choice when a file-only combination is present")
        #expect(combinedSheet.previewField.stringValue.contains("(..)"))
        #expect(combinedSheet.previewField.stringValue.contains(" U  ||----w |"),
                "dead's tongue persists after young replaces its eyes")
        combinedSheet.save()
        #expect(try #require(preserved.configuration).face == "dead, young")

        let replaced = Saved()
        let replacementSheet = makeSheet(combined, saving: replaced)
        replacementSheet.facePopup.selectItem(withTitle: "-w Wired (OO)")
        replacementSheet.save()
        #expect(try #require(replaced.configuration).face == "wired")
    }

    @Test func pinnedFileFontSizeDisablesVariationAndOrdinarySavePreservesBothValues() throws {
        var configuration = Configuration()
        configuration.fontSize = 18.5
        configuration.sizeVariation = 0.75
        let saved = Saved()
        let sheet = makeSheet(configuration, saving: saved)

        #expect(!sheet.sizeVariationBox.isEnabled)
        #expect(sheet.sizeVariationBox.state == .on)
        #expect(!sheet.pinnedFontSizeCaption.isHidden)
        #expect(sheet.pinnedFontSizeCaption.stringValue.contains("18.5"))
        sheet.save()

        let result = try #require(saved.configuration)
        #expect(result.fontSize == 18.5)
        #expect(result.sizeVariation == 0.75)
    }

    @Test func restoreDefaultsResetsDisabledVariationWithoutChangingPinnedFontSize() throws {
        var configuration = Configuration()
        configuration.fontSize = 22
        configuration.sizeVariation = 0.75
        let saved = Saved()
        let sheet = makeSheet(configuration, saving: saved)

        sheet.apply(Configuration())
        #expect(!sheet.sizeVariationBox.isEnabled)
        #expect(sheet.sizeVariationBox.state == .off)
        sheet.save()

        let result = try #require(saved.configuration)
        #expect(result.fontSize == 22)
        #expect(result.sizeVariation == 0)
    }

    @Test func aCompleteRoundTripPreservesEveryFileOnlySetting() throws {
        var configuration = Configuration()
        configuration.fontName = "Courier New"
        configuration.wrapWidth = 73
        configuration.maxFortuneLines = 17
        configuration.fontSize = 18.5
        configuration.weightByFile = true
        configuration.debugFrame = true
        let saved = Saved()
        let sheet = makeSheet(configuration, saving: saved)

        sheet.save()

        let result = try #require(saved.configuration)
        #expect(result.fontName == "Courier New")
        #expect(result.wrapWidth == 73)
        #expect(result.maxFortuneLines == 17)
        #expect(result.fontSize == 18.5)
        #expect(result.weightByFile)
        #expect(result.debugFrame)
    }

    @Test func restoreDefaultsDoesNotPersistAndKeepsFileOnlySettingsUntilOK() throws {
        var configuration = Configuration()
        configuration.rotationSeconds = 5
        configuration.face = "dead, young"
        configuration.fontName = "Courier New"
        configuration.wrapWidth = 73
        configuration.maxFortuneLines = 17
        configuration.fontSize = 18.5
        configuration.foreground = "#123456"
        configuration.background = "#abcdef"
        configuration.theme = nil
        configuration.balloonStyle = "random"
        configuration.randomCow = false
        configuration.cowfiles = ["dragon"]
        configuration.reposition = false
        configuration.adaptiveWrap = false
        configuration.sizeVariation = 0.4
        configuration.transition = "none"
        configuration.weightByFile = true
        configuration.debugFrame = true
        let persistence = Persistence()
        let saved = Saved()
        let sheet = makeSheet(configuration, persister: persistence.persist, saving: saved)

        sheet.apply(Configuration())   // what Restore Defaults hands to apply()

        #expect(persistence.calls.isEmpty, "nothing is written until OK")
        #expect(sheet.rotationField.stringValue == "45")

        sheet.save()

        let result = try #require(saved.configuration)
        #expect(result.rotationSeconds == 45)
        #expect(result.face == Configuration().face, "Restore Defaults resets the Eyes popup")
        #expect(result.fontName == "Courier New")
        #expect(result.wrapWidth == 73)
        #expect(result.maxFortuneLines == 17)
        #expect(result.fontSize == 18.5)
        #expect(result.weightByFile)
        #expect(result.debugFrame)
        #expect(result.foreground == Configuration().foreground,
                "raw colors are controlled by the panel and reset")
        #expect(result.background == Configuration().background)
        #expect(result.theme == Configuration().theme)
        #expect(result.balloonStyle == Configuration().balloonStyle)
        #expect(result.randomCow == Configuration().randomCow)
        #expect(result.cowfiles == ["default", "dragon", "stegosaurus", "tux"])
        #expect(result.reposition == Configuration().reposition)
        #expect(result.adaptiveWrap == Configuration().adaptiveWrap)
        #expect(result.sizeVariation == Configuration().sizeVariation)
        #expect(result.transition == Configuration().transition)
    }

    @Test func restoreDefaultsClearsAStaleValidationMessage() {
        let sheet = makeSheet(saving: Saved())
        sheet.rotationField.stringValue = "0"
        sheet.save()
        #expect(!sheet.errorLabel.isHidden, "the invalid save left a message")

        sheet.apply(Configuration())

        #expect(sheet.errorLabel.isHidden, "Restore Defaults clears a message that no longer applies")
        #expect(sheet.errorLabel.stringValue.isEmpty)
    }

    @Test func aDirectlyConstructedExtremeConfigurationPopulatesTheWindowWithoutTrapping() throws {
        var configuration = Configuration()
        configuration.rotationSeconds = .nan
        configuration.wrapWidth = Int.max
        configuration.maxFortuneLines = Int.min
        configuration.fontSize = .infinity
        configuration.sizeVariation = .infinity

        let saved = Saved()
        let sheet = makeSheet(configuration, saving: saved)

        #expect(sheet.rotationField.stringValue == "45")
        #expect(sheet.sizeVariationBox.state == .off,
                "a non-finite direct value behaves as the default 0")

        sheet.save()

        #expect(try #require(saved.configuration).sizeVariation == 0,
                "no non-finite value reaches the candidate handed to the persister")

        // Every representative non-finite and out-of-range sizeVariation, re-checked from a
        // fresh sheet each time, plus a valid amount to prove the clamp is not overreaching.
        for (direct, expectChecked, expectCandidate): (Double, Bool, Double) in [
            (.nan, false, 0),
            (.infinity, false, 0),
            (-.greatestFiniteMagnitude, false, 0),
            (-5, false, 0),
            (5, true, 0.9),
            (0.75, true, 0.75),
        ] {
            var configuration = Configuration()
            configuration.sizeVariation = direct
            let saved = Saved()
            let sheet = makeSheet(configuration, saving: saved)

            #expect(sheet.sizeVariationBox.state == (expectChecked ? .on : .off),
                    "\(direct): checkbox state")

            sheet.save()

            #expect(try #require(saved.configuration).sizeVariation == expectCandidate,
                    "\(direct): candidate sizeVariation")
        }
    }
}
