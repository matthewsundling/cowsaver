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
        configuration.reposition = false
        configuration.cowfiles = ["dragon", "tux"]

        let sheet = makeSheet(configuration, saving: Saved())

        #expect(sheet.rotationField.stringValue == "12")
        #expect(sheet.wrapField.stringValue == "55")
        #expect(sheet.themePopup.titleOfSelectedItem == "amber")
        #expect(sheet.stylePopup.titleOfSelectedItem == "think")
        #expect(sheet.repositionBox.state == .off)
        #expect(sheet.cowfileBoxes.filter { $0.state == .on }.map(\.title) == ["dragon", "tux"])
    }

    @Test func handsBackEveryControlValueOnOK() throws {
        let saved = Saved()
        let sheet = makeSheet(saving: saved)

        sheet.rotationField.stringValue = "20"
        sheet.wrapField.stringValue = "48"
        sheet.maxLinesField.stringValue = "9"
        sheet.fontSizeField.stringValue = "18"
        sheet.themePopup.selectItem(withTitle: "paperwhite")
        sheet.stylePopup.selectItem(withTitle: "think")
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
        #expect(result.wrapWidth == 48)
        #expect(result.maxFortuneLines == 9)
        #expect(result.fontSize == 18)
        #expect(result.theme == "paperwhite")
        #expect(result.balloonStyle == "think")
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
    /// scrolling, not a window whose buttons sit past the bottom edge (issue #16).
    @Test func aScreenTooShortForTheSheetCapsItAndKeepsTheButtonsInside() throws {
        let cap: CGFloat = 500
        let sheet = makeSheet(cappedAt: cap)
        let content = try #require(sheet.window.contentView)
        content.layoutSubtreeIfNeeded()

        #expect(content.frame.height <= cap, "\(content.frame.height) is taller than the screen")
        let ok = sheet.okButton.convert(sheet.okButton.bounds, to: content)
        #expect(content.bounds.contains(ok),
                "OK at \(ok) is outside the window's \(content.bounds)")
    }

    /// The error footer grows the fixed bottom cluster, not the window: a save failure must
    /// not push the button row (or the message itself) past the same short-screen cap.
    @Test func aVisibleErrorFooterUnderTheShortScreenCapStaysInsideTheWindow() throws {
        let cap: CGFloat = 500
        let persistence = Persistence([.failed("permission denied")])
        let sheet = makeSheet(cappedAt: cap, persister: persistence.persist)

        sheet.save()   // the sheet's default values are valid; the injected persister fails
        #expect(!sheet.errorLabel.isHidden, "the failure must be visible before measuring layout")

        let content = try #require(sheet.window.contentView)
        content.layoutSubtreeIfNeeded()

        #expect(content.frame.height <= cap, "\(content.frame.height) is taller than the screen")
        let controls: [NSView] = [sheet.errorLabel, sheet.restoreButton, sheet.cancelButton,
                                  sheet.okButton]
        for control in controls {
            let frame = control.convert(control.bounds, to: content)
            #expect(content.bounds.contains(frame),
                    "\(control) at \(frame) is outside the window's \(content.bounds)")
        }
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
        sheet.wrapField.stringValue = "77"

        sheet.save()

        #expect(persistence.calls.count == 1, "one attempt")
        #expect(saved.callCount == 0, "the consumer never runs on a failed write")
        #expect(saved.configuration == nil, "the candidate is not accepted")
        #expect(sheet.rotationField.stringValue == "99", "every edited value is retained")
        #expect(sheet.wrapField.stringValue == "77")
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

    @Test("Narrowest wrap column rejects invalid input", arguments: [
        ("1", "one below the lower bound"),
        ("501", "one above the upper bound"),
        ("40.5", "a fraction"),
        ("banana", "non-numeric text"),
        ("", "empty text"),
        ("   ", "whitespace-only text"),
        ("nan", "NaN"),
        ("inf", "positive infinity"),
        ("-inf", "negative infinity"),
        ("1e300", "a huge positive value"),
        ("-1e300", "a huge negative value"),
    ])
    func wrapWidthRejectsInvalidInput(text: String, why: String) {
        assertRejects(\.wrapField, text: text, why: why,
                      messageContains: "Narrowest wrap column")
    }

    @Test("Longest fortune, in lines rejects invalid input", arguments: [
        ("-1", "one below the lower bound"),
        ("101", "one above the upper bound"),
        ("5.5", "a fraction"),
        ("banana", "non-numeric text"),
        ("", "empty text"),
        ("   ", "whitespace-only text"),
        ("nan", "NaN"),
        ("inf", "positive infinity"),
        ("-inf", "negative infinity"),
        ("1e300", "a huge positive value"),
        ("-1e300", "a huge negative value"),
    ])
    func maxFortuneLinesRejectsInvalidInput(text: String, why: String) {
        assertRejects(\.maxLinesField, text: text, why: why,
                      messageContains: "Longest fortune, in lines")
    }

    @Test("Font size rejects invalid input", arguments: [
        ("-1", "a negative value"),
        ("3", "a positive value below 6"),
        ("145", "one above 144"),
        ("banana", "non-numeric text"),
        ("", "empty text"),
        ("   ", "whitespace-only text"),
        ("nan", "NaN"),
        ("inf", "positive infinity"),
        ("-inf", "negative infinity"),
        ("1e300", "a huge positive value"),
        ("-1e300", "a huge negative value"),
    ])
    func fontSizeRejectsInvalidInput(text: String, why: String) {
        assertRejects(\.fontSizeField, text: text, why: why, messageContains: "Font size")
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

    @Test func wrapWidthAcceptsItsBoundariesAndWholeDecimalSpellings() throws {
        for (text, expected) in [("2", 2), ("500", 500), ("40.0", 40)] {
            let saved = Saved()
            let sheet = makeSheet(saving: saved)
            sheet.wrapField.stringValue = text

            sheet.save()

            #expect(try #require(saved.configuration).wrapWidth == expected,
                    "\(text) should be accepted")
        }
    }

    @Test func maxFortuneLinesAcceptsItsBoundaries() throws {
        for (text, expected) in [("0", 0), ("100", 100)] {
            let saved = Saved()
            let sheet = makeSheet(saving: saved)
            sheet.maxLinesField.stringValue = text

            sheet.save()

            #expect(try #require(saved.configuration).maxFortuneLines == expected,
                    "\(text) should be accepted")
        }
    }

    @Test func fontSizeAcceptsAutoFitBoundariesAndInRangeDecimals() throws {
        for (text, expected) in [("0", 0.0), ("6", 6.0), ("144", 144.0), ("18.5", 18.5)] {
            let saved = Saved()
            let sheet = makeSheet(saving: saved)
            sheet.fontSizeField.stringValue = text

            sheet.save()

            #expect(try #require(saved.configuration).fontSize == expected,
                    "\(text) should be accepted")
        }
    }

    // MARK: - Round trip and existing meanings

    @Test func loadedDecimalFontSizeSurvivesDisplayAndSaveUnchanged() throws {
        var configuration = Configuration()
        configuration.fontSize = 18.5
        let saved = Saved()
        let sheet = makeSheet(configuration, saving: saved)

        #expect(sheet.fontSizeField.stringValue == "18.5", "must not truncate the loaded decimal")

        sheet.save()

        #expect(try #require(saved.configuration).fontSize == 18.5)
    }

    @Test func aCompleteRoundTripPreservesEveryFileOnlySetting() throws {
        var configuration = Configuration()
        configuration.face = "dead"
        configuration.fontName = "Courier New"
        configuration.foreground = "#123456"
        configuration.background = "#abcdef"
        configuration.weightByFile = true
        configuration.debugFrame = true
        let saved = Saved()
        let sheet = makeSheet(configuration, saving: saved)

        sheet.save()

        let result = try #require(saved.configuration)
        #expect(result.face == "dead")
        #expect(result.fontName == "Courier New")
        #expect(result.foreground == "#123456")
        #expect(result.background == "#abcdef")
        #expect(result.weightByFile)
        #expect(result.debugFrame)
    }

    @Test func restoreDefaultsDoesNotPersistAndKeepsFileOnlySettingsUntilOK() throws {
        var configuration = Configuration()
        configuration.rotationSeconds = 5
        configuration.face = "dead"
        configuration.fontName = "Courier New"
        configuration.foreground = "#123456"
        configuration.background = "#abcdef"
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
        #expect(result.face == "dead", "file-only settings survive Restore Defaults")
        #expect(result.fontName == "Courier New")
        #expect(result.foreground == "#123456")
        #expect(result.background == "#abcdef")
        #expect(result.weightByFile)
        #expect(result.debugFrame)
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
        #expect(sheet.wrapField.stringValue == "500")
        #expect(sheet.maxLinesField.stringValue == "0")
        #expect(sheet.fontSizeField.stringValue == "0")
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
