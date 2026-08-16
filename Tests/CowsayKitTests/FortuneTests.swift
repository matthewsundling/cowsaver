import Foundation
import Testing
@testable import CowsayKit

@Suite("Fortune parsing")
struct FortuneParsingTests {
    private func parse(_ text: String, options: FortuneLoadOptions = .init()) -> [String] {
        var statistics = FortuneDatabase.Statistics()
        return FortuneDatabase.parse(contents: text, source: "test", options: options,
                                     statistics: &statistics).map(\.text)
    }

    @Test func splitsOnLinesContainingOnlyPercent() {
        #expect(parse("one\n%\ntwo\n%\nthree\n") == ["one", "two", "three"])
    }

    @Test func keepsMultiLineRecordsIntact() {
        #expect(parse("first line\nsecond line\n%\nnext\n") == ["first line\nsecond line", "next"])
    }

    /// A `%` that is not alone on its line is content, not a separator.
    @Test func percentInsideALineIsNotASeparator() {
        #expect(parse("100% sure\n%\nnext\n") == ["100% sure", "next"])
    }

    @Test func normalisesCRLFAndDropsEmptyRecords() {
        #expect(parse("one\r\n%\r\n\r\n%\r\ntwo\r\n") == ["one", "two"])
    }

    @Test func dropsRecordsTallerThanTheLineLimit() {
        #expect(parse("short\n%\n\(tallRecord)\n") == ["short"])
    }

    /// Line limits preserve readable long prose that a character limit would reject.
    @Test func keepsRecordsThatAreLongButNotTall() {
        let long = String(repeating: "word ", count: 120)   // ~600 characters, 15 lines
        #expect(parse(long).count == 1)
    }

    @Test func maxLinesOfZeroMeansNoLimit() {
        #expect(parse(tallRecord, options: FortuneLoadOptions(maxLines: 0)).count == 1)
    }

    /// Roughly ninety lines when wrapped at the default width.
    private var tallRecord: String { String(repeating: "word ", count: 700) }

    /// The screensaver filters non-ASCII text because cowsay's byte wrapping can split a
    /// multi-byte character at a line boundary.
    @Test func filtersNonASCIIRecords() {
        #expect(parse("plain\n%\ncafé\n%\n日本語\n") == ["plain"])
    }

    @Test func keepsNonASCIIWhenFilteringIsDisabled() {
        let options = FortuneLoadOptions(filterUnsafeCharacters: false)
        #expect(parse("plain\n%\ncafé\n", options: options) == ["plain", "café"])
    }

    @Test func skipsSeparatelyDistributedFortuneFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowsaver-fortune-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "keep\n".write(to: directory.appendingPathComponent("regular"),
                             atomically: true, encoding: .utf8)
        try "skip\n".write(to: directory.appendingPathComponent("legacy-o"),
                             atomically: true, encoding: .utf8)
        let off = directory.appendingPathComponent("off")
        try FileManager.default.createDirectory(at: off, withIntermediateDirectories: true)
        try "skip\n".write(to: off.appendingPathComponent("separate"),
                             atomically: true, encoding: .utf8)

        let database = FortuneDatabase.load(directories: [directory])
        #expect(database.fortunes.map(\.text) == ["keep"])
    }

    @Test func countsWhatItDropped() {
        var statistics = FortuneDatabase.Statistics()
        _ = FortuneDatabase.parse(
            contents: "ok\n%\n\(String(repeating: "word ", count: 700))\n%\ncafé\n",
            source: "t", options: .init(), statistics: &statistics
        )
        #expect(statistics.droppedTooTall == 1)
        #expect(statistics.droppedUnsafe == 1)
    }

    /// The `%` format has no comment syntax. Cowsaver reserves a leading `##` block for
    /// per-file source and licence metadata, which is not a quote record.
    @Test func skipsTheLeadingLicenceHeader() {
        #expect(parse("## a header\n## second line\nfirst real record\n%\nsecond\n")
                == ["first real record", "second"])
    }

    /// …but only at the top of the file.
    @Test func doesNotSkipHashesInsideRecords() {
        #expect(parse("real\n%\n## not a header here\n") == ["real", "## not a header here"])
    }

}

// MARK: - Bundled curated corpus

@Suite("Bundled fortune corpus")
struct BundledFortuneTests {
    static let database = FortuneDatabase.load(
        directories: [GoldenTests.repositoryRoot.appendingPathComponent("Resources/fortune-curated")]
    )

    @Test func loadsTheCuratedCorpusFile() {
        #expect(Self.database.statistics.filesRead == 1,
                "got \(Self.database.statistics.filesRead)")
    }

    @Test func hasTheExpectedCuratedRecordCount() {
        #expect(Self.database.fortunes.count == 3_493,
                "got \(Self.database.fortunes.count)")
    }

    @Test func curationManifestMatchesTheRuntimeCorpus() throws {
        let manifest = GoldenTests.repositoryRoot
            .appendingPathComponent("Resources/fortune-curated/curation.tsv")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        let rows = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map {
            $0.split(separator: "\t", omittingEmptySubsequences: false)
        }

        #expect(rows.count == 13_353, "got \(rows.count)")
        #expect(rows.allSatisfy { $0.count == 5 })

        let retained = rows.compactMap { fields -> String? in
            guard fields.count == 5, fields[3] == "retain" else { return nil }
            return String(fields[0])
        }.sorted()
        let runtime = Self.database.fortunes.map(\.id).sorted()
        #expect(retained == runtime)
    }

    /// Documentation shipped alongside the data must never be parsed as a quote. Getting
    /// this wrong would put our own licence text on the screen.
    @Test func metadataFilesAreNotParsedAsFortunes() {
        let sources = Set(Self.database.fortunes.map(\.source))
        for name in ["curation.tsv"] {
            #expect(!sources.contains { $0.hasSuffix(name) }, "\(name) was parsed as data")
        }
        #expect(!Self.database.fortunes.contains { $0.text.contains("sha256") })
    }


    @Test func everyRecordIsSafeAndWellFormed() {
        for fortune in Self.database.fortunes {
            #expect(FortuneDatabase.isSafe(fortune.text), "unsafe: \(fortune.text)")
            #expect(FortuneDatabase.wrappedLineCount(fortune.text, columns: 40) <= 60,
                    "too tall: \(fortune.text)")
            #expect(fortune.text == fortune.text.trimmingCharacters(in: .whitespacesAndNewlines))
            #expect(!fortune.text.isEmpty)
        }
    }

    /// The height-filter bound must never underestimate the exact wrapper. Check it for every
    /// bundled record at every width used by adaptive wrapping.
    @Test(arguments: [40, 60, 80, 100, 120])
    func boundIsSafeForTheWholeCorpus(columns: Int) {
        for fortune in Self.database.fortunes {
            let bound = FortuneDatabase.upperBoundOnLines(fortune.text, columns: columns)
            let actual = FortuneDatabase.wrappedLineCount(fortune.text, columns: columns)
            #expect(bound >= actual, "bound \(bound) < actual \(actual): \(fortune.text)")
        }
    }

    /// Long unbreakable words exercise the bound's two-lines-per-width allowance.
    @Test func boundSurvivesAdversarialInput() {
        let awkward = [
            String(repeating: "x", count: 5_000),
            String(repeating: "a ", count: 1_000),
            String(repeating: "ab ", count: 500) + String(repeating: "z", count: 500),
            (0 ..< 200).map { _ in "short " + String(repeating: "q", count: 38) }.joined(),
            String(repeating: "\n  paragraph break\n", count: 60),
            String(repeating: " ", count: 2_000),
        ]
        for columns in [2, 40, 120] {
            for text in awkward {
                let bound = FortuneDatabase.upperBoundOnLines(text, columns: columns)
                let actual = FortuneDatabase.wrappedLineCount(text, columns: columns)
                #expect(bound >= actual, "at -W \(columns): bound \(bound) < actual \(actual)")
            }
        }
    }

    /// A licence header that leaked into the corpus would be shown to users as a fortune.
    @Test func noLicenceHeaderLeakedIntoTheRecords() {
        #expect(!Self.database.fortunes.contains { $0.text.hasPrefix("##") })
        #expect(!Self.database.fortunes.contains { $0.text.contains("License: GPLv3") })
    }

    /// Every bundled fortune must render through the normal cow pipeline.
    @Test func everyRecordRendersThroughACow() throws {
        let cow = try #require(GoldenTests.library.cow(named: "stegosaurus"))
        for fortune in Self.database.fortunes {
            #expect(!CowRenderer.render(message: fortune.text, cowfile: cow).isEmpty)
        }
    }

    /// Quote identifiers must be stable and unambiguous within the bundled collection.
    @Test func recordIdentifiersAreStableAndDistinct() {
        let identifiers = Self.database.fortunes.map(\.id)
        #expect(identifiers.allSatisfy { $0.count == 16 })
        // Collisions would make a removal request ambiguous.
        let unique = Set(identifiers).count
        let duplicateTexts = Set(Self.database.fortunes.map(\.text)).count
        #expect(unique == duplicateTexts,
                "identifier collision: \(unique) ids for \(duplicateTexts) distinct texts")
    }

    @Test func identifiersDependOnlyOnTheText() {
        let a = Fortune(text: "  spaced out  ", source: "one")
        let b = Fortune(text: "spaced out", source: "two")
        #expect(a.id == b.id, "an ID must survive re-import, renaming and reordering")
    }
}

/// Optional exclusion lists suppress selected stable quote identifiers during loading.
@Suite("Quote exclusion")
struct ExclusionTests {
    private func parse(_ text: String, excluded: Set<String>) -> [String] {
        var statistics = FortuneDatabase.Statistics()
        return FortuneDatabase.parse(contents: text, source: "t", options: .init(),
                                     excluded: excluded,
                                     statistics: &statistics).map(\.text)
    }

    @Test func suppressesAnExcludedRecord() {
        let target = Fortune.identifier(for: "remove me")
        #expect(parse("keep me\n%\nremove me\n%\nkeep this too\n", excluded: [target])
                == ["keep me", "keep this too"])
    }

    @Test func exclusionIsCountedSoItIsVisible() {
        var statistics = FortuneDatabase.Statistics()
        _ = FortuneDatabase.parse(contents: "a\n%\nb\n", source: "t", options: .init(),
                                  excluded: [Fortune.identifier(for: "b")],
                                  statistics: &statistics)
        #expect(statistics.droppedExcluded == 1)
    }

    @Test func anEmptyExclusionListChangesNothing() {
        #expect(parse("a\n%\nb\n", excluded: []) == ["a", "b"])
    }

    /// A collection without excluded.txt has no exclusions.
    @Test func absentExclusionFileProducesAnEmptySet() {
        let directory = GoldenTests.repositoryRoot
            .appendingPathComponent("Resources/fortune-curated")
        #expect(FortuneDatabase.loadExclusions(in: directory).isEmpty)
    }
}

@Suite("SHA-256")
struct SHA256Tests {
    /// Standard vectors. This is hand-written rather than CryptoKit so that CowsayKit
    /// stays Foundation-only, which means it has to be checked against known answers.
    @Test(arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ("hello world", "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"),
        ("The quick brown fox jumps over the lazy dog",
         "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"),
    ])
    func matchesKnownVectors(input: String, expected: String) {
        #expect(SHA256.hex(Array(input.utf8), prefixLength: 64) == expected)
    }

    /// Longer than one 64-byte block, to exercise the chunk loop.
    @Test func handlesMultiBlockInput() {
        let input = String(repeating: "a", count: 1000)
        #expect(SHA256.hex(Array(input.utf8), prefixLength: 64)
                == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }
}

// MARK: - Selection

@Suite("Selection")
struct SelectionTests {
    private let fortunes = (0 ..< 50).map { Fortune(text: "f\($0)", source: "test") }

    @Test func isDeterministicForAGivenSeed() {
        var a = NoRepeatSelector(elements: fortunes, seed: 42)
        var b = NoRepeatSelector(elements: fortunes, seed: 42)
        for _ in 0 ..< 20 { #expect(a.next()?.text == b.next()?.text) }
    }

    @Test func differentSeedsDiverge() {
        var a = NoRepeatSelector(elements: fortunes, seed: 1)
        var b = NoRepeatSelector(elements: fortunes, seed: 2)
        let first = (0 ..< 20).map { _ in a.next()?.text }
        let second = (0 ..< 20).map { _ in b.next()?.text }
        #expect(first != second, "two displays would show identical text in lockstep")
    }

    @Test func neverRepeatsWithinTheHistoryWindow() {
        var selector = NoRepeatSelector(elements: fortunes, historyLimit: 20, seed: 7)
        var recent: [String] = []
        for _ in 0 ..< 200 {
            guard let next = selector.next()?.text else { return #expect(Bool(false)) }
            #expect(!recent.contains(next), "repeated \(next) within the window")
            recent.append(next)
            if recent.count > 20 { recent.removeFirst() }
        }
    }

    /// A corpus smaller than the history window must still make progress rather than
    /// deadlocking looking for an unseen element.
    @Test(arguments: [1, 2, 3, 5])
    func smallCorporaStillTerminate(size: Int) {
        var selector = NoRepeatSelector(elements: Array(fortunes.prefix(size)),
                                        historyLimit: 20, seed: 3)
        for _ in 0 ..< 100 { #expect(selector.next() != nil) }
    }

    @Test func emptyCorpusYieldsNil() {
        var selector = NoRepeatSelector(elements: [Fortune](), seed: 1)
        #expect(selector.next() == nil)
    }

    @Test func weightingByFileFavoursLargerFiles() {
        let database = FortuneDatabase(
            fortunes: [Fortune(text: "small", source: "a"), Fortune(text: "big", source: "b")],
            weights: ["a": 1, "b": 999]
        )
        var selector = NoRepeatSelector(database: database, historyLimit: 0,
                                        seed: 11, weightByFile: true)
        let picks = (0 ..< 200).compactMap { _ in selector.next()?.text }
        #expect(picks.filter { $0 == "big" }.count > picks.filter { $0 == "small" }.count)
    }
}
