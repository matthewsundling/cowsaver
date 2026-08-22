import Foundation
import Testing
@testable import CowsayKit

@Suite("Resource root identity")
struct ResourceIdentityTests {
    private func fixtureDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowsaver-resource-identity-\(name)")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    private func writeCow(_ body: String, to directory: URL, named name: String) throws {
        try write("""
        $the_cow = <<'EOC';
        \(body)
        EOC
        """, to: directory.appendingPathComponent(name).appendingPathExtension("cow"))
    }

    @Test func usableBundleCollectionsSuppressCheckoutFallbacks() throws {
        let root = try fixtureDirectory("usable-bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleResources = root.appendingPathComponent("bundle/Resources")
        let checkoutResources = root.appendingPathComponent("checkout/Resources")
        for subdirectory in ["cows", "fortune-curated"] {
            try FileManager.default.createDirectory(
                at: bundleResources.appendingPathComponent(subdirectory), withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: checkoutResources.appendingPathComponent(subdirectory), withIntermediateDirectories: true
            )
        }

        #expect(ResourceLocations.cowDirectories(
            bundleResourceURL: bundleResources, developmentResourceURL: checkoutResources
        ) == [bundleResources.appendingPathComponent("cows").standardizedFileURL])
        #expect(ResourceLocations.fortuneDirectories(
            supportDirectories: [], bundleResourceURL: bundleResources,
            developmentResourceURL: checkoutResources
        ) == [bundleResources.appendingPathComponent("fortune-curated").standardizedFileURL])
    }

    @Test func missingBundleCollectionsUseCheckoutFallbacks() throws {
        let root = try fixtureDirectory("missing-bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleResources = root.appendingPathComponent("bundle/Resources")
        let checkoutResources = root.appendingPathComponent("checkout/Resources")
        let checkoutCows = checkoutResources.appendingPathComponent("cows")
        let checkoutFortunes = checkoutResources.appendingPathComponent("fortune-curated")
        try FileManager.default.createDirectory(at: bundleResources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkoutCows, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkoutFortunes, withIntermediateDirectories: true)
        try writeCow("checkout cow", to: checkoutCows, named: "checkout")
        try write("checkout fortune\n", to: checkoutFortunes.appendingPathComponent("quotes"))

        let cows = ResourceLocations.cowDirectories(
            bundleResourceURL: bundleResources, developmentResourceURL: checkoutResources
        )
        let fortunes = ResourceLocations.fortuneDirectories(
            supportDirectories: [], bundleResourceURL: bundleResources,
            developmentResourceURL: checkoutResources
        )
        #expect(CowfileLibrary.load(directories: cows).cow(named: "checkout") != nil)
        #expect(FortuneDatabase.load(directories: fortunes).fortunes.map(\.text)
                == ["checkout fortune"])
    }

    @Test func loadersNormalizeRootsWithoutDuplicatingScansOrReversingCowPrecedence() throws {
        let root = try fixtureDirectory("normalized-loaders")
        defer { try? FileManager.default.removeItem(at: root) }
        let fortunes = root.appendingPathComponent("fortunes")
        let firstCows = root.appendingPathComponent("first-cows")
        let secondCows = root.appendingPathComponent("second-cows")
        for directory in [fortunes, firstCows, secondCows] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write("one record\n", to: fortunes.appendingPathComponent("quotes"))
        try writeCow("first root", to: firstCows, named: "shared")
        try write("not a cowfile", to: firstCows.appendingPathComponent("broken.cow"))
        try writeCow("second root", to: secondCows, named: "shared")

        let equivalentFortunes = fortunes.deletingLastPathComponent()
            .appendingPathComponent("fortunes/./")
        let database = FortuneDatabase.load(directories: [fortunes, equivalentFortunes, fortunes])
        #expect(database.fortunes.count == 1)
        #expect(database.statistics.filesRead == 1)
        #expect(database.weights.count == 1)

        let equivalentFirstCows = firstCows.deletingLastPathComponent()
            .appendingPathComponent("first-cows/./")
        let library = CowfileLibrary.load(
            directories: [firstCows, equivalentFirstCows, secondCows]
        )
        let shared = try #require(library.cow(named: "shared"))
        #expect(String(decoding: CowRenderer.render(message: "", cowfile: shared), as: UTF8.self)
                .contains("first root"))
        #expect(library.failures.count == 1)
    }

    @Test func sameRelativeFortuneFilesHaveIndependentRootQualifiedSources() throws {
        let root = try fixtureDirectory("source-collision")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("personal")
        let second = root.appendingPathComponent("bundled")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let firstContents = "same quote\n%\nfirst only\n"
        let secondContents = "same quote\n%\nsecond collection has more bytes\n"
        let firstFile = first.appendingPathComponent("quotes")
        let secondFile = second.appendingPathComponent("quotes")
        try write(firstContents, to: firstFile)
        try write(secondContents, to: secondFile)

        let database = FortuneDatabase.load(directories: [first, second])
        let firstSource = firstFile.standardizedFileURL.path
        let secondSource = secondFile.standardizedFileURL.path
        #expect(database.fortunes.count == 4)
        #expect(firstSource != secondSource)
        #expect(Set(database.fortunes.map(\.source)) == [firstSource, secondSource])
        #expect(database.weights[firstSource] == Data(firstContents.utf8).count)
        #expect(database.weights[secondSource] == Data(secondContents.utf8).count)

        let repeated = database.fortunes.filter { $0.text == "same quote" }
        #expect(repeated.count == 2)
        #expect(Set(repeated.map(\.source)).count == 2)
        #expect(Set(repeated.map(\.id)).count == 1)
    }

    @Test func directParserKeepsItsCallerSuppliedSource() {
        var statistics = FortuneDatabase.Statistics()
        let fortunes = FortuneDatabase.parse(contents: "direct\n", source: "caller-source",
                                             statistics: &statistics)
        #expect(fortunes.map(\.source) == ["caller-source"])
    }

    @Test func packagedCollectionLoadsOnceWhenCheckoutResourcesAlsoExist() throws {
        let root = try fixtureDirectory("packaged-corpus")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleResources = root.appendingPathComponent("Cowsaver.app/Contents/Resources")
        let checkoutResources = GoldenTests.repositoryRoot.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: bundleResources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: checkoutResources.appendingPathComponent("fortune-curated"),
            to: bundleResources.appendingPathComponent("fortune-curated")
        )

        let directories = ResourceLocations.fortuneDirectories(
            supportDirectories: [], bundleResourceURL: bundleResources,
            developmentResourceURL: checkoutResources
        )
        let database = FortuneDatabase.load(directories: directories)
        #expect(directories == [bundleResources.appendingPathComponent("fortune-curated")
            .standardizedFileURL])
        #expect(database.fortunes.count == 3_470)
        #expect(database.statistics.filesRead == 1)
        #expect(database.fortunes.allSatisfy {
            $0.source == bundleResources.appendingPathComponent("fortune-curated/fortunes")
                .standardizedFileURL.path
        })

        // The packaged collection is well within every loading limit.
        #expect(!database.statistics.entryLimitReached)
        #expect(!database.statistics.aggregateByteLimitReached)
        #expect(!database.statistics.recordLimitReached)
        #expect(database.statistics.oversizedFilesSkipped == 0)
        #expect(database.statistics.unreadableFilesSkipped == 0)
        #expect(database.statistics.invalidUTF8FilesSkipped == 0)
        #expect(database.statistics.symbolicLinksSkipped == 0)
        #expect(database.issues.isEmpty)
    }
}
