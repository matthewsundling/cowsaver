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

    /// Holds what OK handed back.
    private final class Saved {
        var configuration: Configuration?
    }

    private func makeSheet(_ configuration: Configuration = Configuration(),
                           saving saved: Saved) -> ConfigurationSheet {
        ConfigurationSheet(configuration: configuration, cowfileNames: cowfileNames) {
            saved.configuration = $0
        }
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
        #expect(result.transition == "none")
        #expect(result.cowfiles == ["dragon", "tux"], "checked names, in the order listed")
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
}
