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

    /// The "off" convention matches a directory *component*, not a substring: a directory
    /// named `handoff` or `office` merely contains the letters and must load normally,
    /// while `off` nested below another directory is excluded exactly like a root-level one.
    @Test func offComponentMatchingIsExactNotSubstring() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowsaver-off-component-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let nestedOff = directory.appendingPathComponent("a/off")
        try FileManager.default.createDirectory(at: nestedOff, withIntermediateDirectories: true)
        try "skip\n".write(to: nestedOff.appendingPathComponent("quotes"),
                           atomically: true, encoding: .utf8)

        let handoff = directory.appendingPathComponent("handoff")
        try FileManager.default.createDirectory(at: handoff, withIntermediateDirectories: true)
        try "handoff quote\n".write(to: handoff.appendingPathComponent("quotes"),
                                    atomically: true, encoding: .utf8)

        let office = directory.appendingPathComponent("office")
        try FileManager.default.createDirectory(at: office, withIntermediateDirectories: true)
        try "office quote\n".write(to: office.appendingPathComponent("quotes"),
                                   atomically: true, encoding: .utf8)

        // "-o" is a filename suffix rule, not a substring test: only a name that actually
        // ends in "-o" is skipped.
        try "mid-o-name quote\n".write(to: directory.appendingPathComponent("mid-o-name"),
                                       atomically: true, encoding: .utf8)
        try "skip\n".write(to: directory.appendingPathComponent("trailing-o"),
                           atomically: true, encoding: .utf8)

        let database = FortuneDatabase.load(directories: [directory])
        #expect(Set(database.fortunes.map(\.text))
                == ["handoff quote", "office quote", "mid-o-name quote"])
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
        #expect(Self.database.fortunes.count == 3_470,
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
        let database = FortuneDatabase.load(directories: [directory])
        #expect(database.statistics.droppedExcluded == 0)
    }
}

// MARK: - Bounded loading

/// Loading-limit tests inject small `FortuneDatabase.Limits` values through the internal
/// overload rather than constructing production-sized fixtures repeatedly. The production
/// constants themselves are asserted directly.
///
/// `load()` requests entries incrementally and does not accumulate or sort a directory
/// listing itself, so within one root the filesystem decides visiting order. Tests that
/// need a controlled order put each file in its own root instead:
/// `ResourceLocations.standardizedDirectories` preserves root order even though file
/// order within one directory is never promised.
@Suite("Bounded personal loading")
struct BoundedLoadingTests {
    private func fixtureDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowsaver-bounded-loading-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func productionLimitsMatchTheDocumentedValues() {
        let limits = FortuneDatabase.Limits.production
        #expect(limits.maxFileBytes == 8 * 1024 * 1024)
        #expect(limits.maxAggregateBytes == 32 * 1024 * 1024)
        #expect(limits.maxRetainedRecords == 100_000)
        #expect(limits.maxExaminedEntries == 1_000)
    }

    // MARK: Per-file and aggregate byte boundaries

    @Test func perFileByteLimitAcceptsTheBoundaryAndSkipsOneByteOverWhileALaterFileStillLoads() throws {
        let directory = try fixtureDirectory("per-file")
        defer { try? FileManager.default.removeItem(at: directory) }
        let atLimit = "0123456789abcde\n"   // exactly 16 bytes
        #expect(Data(atLimit.utf8).count == 16)
        let overLimit = atLimit + "x"       // 17 bytes: one over the boundary

        try Data(overLimit.utf8).write(to: directory.appendingPathComponent("a-oversized"))
        try Data(atLimit.utf8).write(to: directory.appendingPathComponent("b-at-limit"))

        let limits = FortuneDatabase.Limits(maxFileBytes: 16, maxAggregateBytes: 1_000_000,
                                            maxRetainedRecords: 1_000, maxExaminedEntries: 1_000)
        let database = FortuneDatabase.load(directories: [directory], options: .init(), limits: limits)

        #expect(database.statistics.oversizedFilesSkipped == 1)
        #expect(database.statistics.filesRead == 1)
        #expect(database.fortunes.map(\.text) == ["0123456789abcde"],
                "the exactly-16-byte file at the boundary must still load")
        #expect(database.issues.contains { $0.contains("a-oversized") && $0.contains("larger than") })
    }

    /// Each file's outcome is put in its own root so their order in the fixture cannot
    /// matter: `load` preserves root order but never file order within one root.
    @Test func aggregateByteLimitAcceptsTheBoundaryThenStopsFurtherLoadWork() throws {
        let firstRoot = try fixtureDirectory("aggregate-first")
        defer { try? FileManager.default.removeItem(at: firstRoot) }
        let secondRoot = try fixtureDirectory("aggregate-second")
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        let content = "0123456789abcde\n"   // 16 bytes, one record
        try Data(content.utf8).write(to: firstRoot.appendingPathComponent("a-first"))
        try Data(content.utf8).write(to: secondRoot.appendingPathComponent("b-second"))

        let limits = FortuneDatabase.Limits(maxFileBytes: 1_000, maxAggregateBytes: 16,
                                            maxRetainedRecords: 1_000, maxExaminedEntries: 1_000)
        let database = FortuneDatabase.load(directories: [firstRoot, secondRoot], options: .init(),
                                            limits: limits)

        #expect(database.statistics.filesRead == 1,
                "the first root's file exactly meets the 16-byte aggregate boundary and loads")
        #expect(database.statistics.aggregateByteLimitReached)
        #expect(database.fortunes.map(\.text) == ["0123456789abcde"])
    }

    /// A malicious or corrupt file can report almost any size in its metadata — a real
    /// fixture cannot portably force `FileManager` to report a near-`Int.max` file size, so
    /// this drives the accumulator directly with the extreme value a poisoned
    /// `URLResourceValues.fileSize` would otherwise pass it.
    @Test func aggregateByteLimitCannotOverflowWhenFileMetadataReportsAnExtremeSize() {
        let limits = FortuneDatabase.Limits(maxFileBytes: Int.max, maxAggregateBytes: 1_000_000,
                                            maxRetainedRecords: 1_000, maxExaminedEntries: 1_000)
        let budget = FortuneDatabase.LoadBudget(limits: limits)

        #expect(budget.reserveAggregateBytes(1_000), "an ordinary reservation still succeeds")
        #expect(!budget.reserveAggregateBytes(Int.max),
                "1_000 + Int.max wraps past Int.max and must be rejected, not crash")
        #expect(budget.statistics.aggregateByteLimitReached)
    }

    // MARK: Actual bytes read, not stated metadata

    /// A candidate that cannot be read must not be charged for its stated size — tested
    /// directly against the accumulator, independent of filesystem enumeration order.
    @Test func unreadableReadDoesNotChargeAggregateBytes() {
        let limits = FortuneDatabase.Limits(maxFileBytes: 1_000, maxAggregateBytes: 10,
                                            maxRetainedRecords: 1_000, maxExaminedEntries: 1_000)
        let budget = FortuneDatabase.LoadBudget(limits: limits)

        let outcome = budget.readBounded(atPath: "/does/not/matter", statedSize: 5,
                                         reader: { _, _ in nil })
        guard case .unreadable = outcome else {
            Issue.record("expected .unreadable, got \(outcome)")
            return
        }
        // Nothing was charged: the full 10-byte budget is still available.
        #expect(budget.reserveAggregateBytes(10))
    }

    /// The same guarantee end to end: an unreadable file's stated size must not shrink the
    /// budget a later file needs. Each file gets its own root so `load`'s guaranteed root
    /// order — not the unpromised file order within one root — puts the unreadable file
    /// first.
    @Test func unreadableFileConsumesNoAggregateBytesAndALaterValidFileStillLoads() throws {
        let unreadableRoot = try fixtureDirectory("unreadable-root")
        defer { try? FileManager.default.removeItem(at: unreadableRoot) }
        try Data("dummy\n".utf8).write(to: unreadableRoot.appendingPathComponent("a-unreadable"))

        let validRoot = try fixtureDirectory("valid-root")
        defer { try? FileManager.default.removeItem(at: validRoot) }
        let validContent = "keeps loading\n"
        try Data(validContent.utf8).write(to: validRoot.appendingPathComponent("b-valid"))

        // Sized to fit only one file's worth of content. If the unreadable file's stated
        // size were wrongly charged, this budget would already be exhausted by the time
        // the valid file is read.
        let limits = FortuneDatabase.Limits(
            maxFileBytes: 1_000, maxAggregateBytes: Data(validContent.utf8).count,
            maxRetainedRecords: 1_000, maxExaminedEntries: 1_000
        )
        let database = FortuneDatabase.load(
            directories: [unreadableRoot, validRoot], options: .init(), limits: limits,
            reader: { path, maxBytes in
                (path as NSString).lastPathComponent == "a-unreadable"
                    ? nil : FileManager.default.contents(atPath: path)?.prefix(maxBytes)
            }
        )

        #expect(database.statistics.unreadableFilesSkipped == 1)
        #expect(!database.statistics.aggregateByteLimitReached,
                "the unreadable file's stated size must not have been charged")
        #expect(database.fortunes.map(\.text) == ["keeps loading"])
    }

    /// Metadata said this file fit, but the bytes actually read exceed the per-file cap —
    /// simulating a file that grew between the stat and the read. Rejected as oversized,
    /// not mistaken for an aggregate exhaustion, and traversal continues.
    @Test func readResultOverThePerFileCapIsRejectedEvenWhenMetadataSaysItFits() throws {
        let directory = try fixtureDirectory("race-per-file")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("x\n".utf8).write(to: directory.appendingPathComponent("a-grows"))
        try Data("ok\n".utf8).write(to: directory.appendingPathComponent("b-normal"))   // 3 bytes

        let limits = FortuneDatabase.Limits(maxFileBytes: 10, maxAggregateBytes: 1_000_000,
                                            maxRetainedRecords: 1_000, maxExaminedEntries: 1_000)
        let database = FortuneDatabase.load(
            directories: [directory], options: .init(), limits: limits,
            reader: { path, maxBytes in
                (path as NSString).lastPathComponent == "a-grows"
                    ? Data(repeating: 0x61, count: maxBytes)   // always fills whatever is asked
                    : FileManager.default.contents(atPath: path)
            }
        )

        #expect(database.statistics.oversizedFilesSkipped == 1)
        #expect(!database.statistics.aggregateByteLimitReached,
                "a per-file rejection must not be mistaken for an aggregate one")
        #expect(database.issues.contains { $0.contains("a-grows") && $0.contains("larger than") })
        #expect(database.fortunes.map(\.text) == ["ok"])
    }

    /// Metadata said this file fit the (generous) per-file cap, but the bytes actually
    /// read exceed the remaining aggregate cap. Attributed to the aggregate rule, which
    /// stops the whole load rather than merely skipping this one file.
    @Test func readResultOverTheRemainingAggregateCapStopsTheWholeLoad() throws {
        let directory = try fixtureDirectory("race-aggregate")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("x\n".utf8).write(to: directory.appendingPathComponent("grows"))

        let limits = FortuneDatabase.Limits(maxFileBytes: 1_000_000, maxAggregateBytes: 10,
                                            maxRetainedRecords: 1_000, maxExaminedEntries: 1_000)
        let database = FortuneDatabase.load(
            directories: [directory], options: .init(), limits: limits,
            reader: { _, maxBytes in Data(repeating: 0x61, count: maxBytes) }
        )

        #expect(database.statistics.aggregateByteLimitReached)
        #expect(database.statistics.oversizedFilesSkipped == 0)
        #expect(database.fortunes.isEmpty)
    }

    // MARK: Records

    /// Records before the cap keep their normal filtering; a record positioned after it
    /// is never even inspected, so it is not counted either way.
    @Test func recordLimitRetainsExactlyTheBoundaryWithoutParsingBeyondIt() throws {
        let directory = try fixtureDirectory("record-limit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = ["record0", "café-before-the-cap", "record1", "record2", "record3",
                       "café-after-the-cap"].joined(separator: "\n%\n")
        try Data(content.utf8).write(to: directory.appendingPathComponent("quotes"))

        let limits = FortuneDatabase.Limits(maxFileBytes: 1_000_000, maxAggregateBytes: 1_000_000,
                                            maxRetainedRecords: 4, maxExaminedEntries: 1_000)
        let database = FortuneDatabase.load(directories: [directory], options: .init(), limits: limits)

        #expect(database.fortunes.map(\.text) == ["record0", "record1", "record2", "record3"])
        #expect(database.statistics.recordLimitReached)
        #expect(database.statistics.droppedUnsafe == 1,
                "only the unsafe record before the cap was ever inspected")
    }

    /// Counts lines actually visited by the incremental parser, proving the scan stops at
    /// the delimiter that retains the last allowed record. A dense tail makes an eager
    /// whole-input line collection materially different from the intended implementation.
    @Test func recordLimitStopsScanningLaterLinesEntirely() {
        let maxRecords = 4
        let allRecords = (0 ..< 50_000).map { "record\($0)" }
        let content = allRecords.joined(separator: "\n%\n")
        var statistics = FortuneDatabase.Statistics()
        var linesVisited = 0

        let out = FortuneDatabase.parse(
            contents: content, source: "t", options: .init(), excluded: [],
            statistics: &statistics, maxRecords: maxRecords,
            lineObserver: { linesVisited += 1 }
        )

        #expect(out.map(\.text) == Array(allRecords.prefix(maxRecords)))
        #expect(statistics.recordLimitReached)
        // Four content lines and their four delimiters are visited. The fifth record's
        // content and the rest of the dense tail are never visited.
        #expect(linesVisited == 2 * maxRecords, "got \(linesVisited)")
        #expect(linesVisited < allRecords.count * 2 - 1)
    }

    @Test func aReadErrorAfterAChunkRejectsThePartialPrefix() {
        struct PartialReadError: Error {}
        var callCount = 0

        let data = FortuneDatabase.collectBoundedData(maxBytes: 10) { _ in
            callCount += 1
            if callCount == 1 { return Data("partial".utf8) }
            throw PartialReadError()
        }

        #expect(data == nil)
        #expect(callCount == 2)
    }

    @Test func cleanEndOfFileAcceptsTheChunksReadSoFar() {
        var chunks: [Data?] = [Data("complete".utf8), nil]
        let data = FortuneDatabase.collectBoundedData(maxBytes: 10) { _ in
            chunks.removeFirst()
        }

        #expect(data == Data("complete".utf8))
    }

    // MARK: Entry accounting

    /// With a budget generous enough to examine everything, every kind of real
    /// descendant — a directory, its own child, a symbolic link, an intentionally
    /// ignored index file, and an eligible fortune file — is counted exactly once, and
    /// nothing is double-charged by exclusion discovery sharing the same walk.
    @Test func entryAccountingCountsEveryRealDescendantKindExactlyOnce() throws {
        let directory = try fixtureDirectory("entry-accounting")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = try fixtureDirectory("entry-accounting-outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside secret\n".utf8).write(to: outside.appendingPathComponent("target"))

        let sub = directory.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("inner fortune\n".utf8).write(to: sub.appendingPathComponent("inner"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link"),
            withDestinationURL: outside.appendingPathComponent("target")
        )
        try Data("ignored\n".utf8).write(to: directory.appendingPathComponent("index.dat"))
        try Data("root fortune\n".utf8).write(to: directory.appendingPathComponent("quotes"))

        // 5 real descendants: sub, sub/inner, link, index.dat, quotes.
        let limits = FortuneDatabase.Limits(maxFileBytes: 1_000_000, maxAggregateBytes: 1_000_000,
                                            maxRetainedRecords: 1_000, maxExaminedEntries: 5)
        let database = FortuneDatabase.load(directories: [directory], options: .init(), limits: limits)

        #expect(database.statistics.entriesExamined == 5)
        #expect(!database.statistics.entryLimitReached, "5 real descendants exactly fit a cap of 5")
        #expect(database.statistics.symbolicLinksSkipped == 1)
        #expect(database.statistics.filesRead == 2)
        #expect(Set(database.fortunes.map(\.text)) == ["inner fortune", "root fortune"])
        #expect(!database.fortunes.contains { $0.text.contains("outside secret") })
    }

    /// The same fixture with a cap smaller than the real descendant count stops
    /// traversal with a diagnostic rather than silently truncating, and the cap is
    /// clearly counting filesystem entries rather than parsed fortunes: it stops at 3
    /// even though only some of those 3 could ever have been fortune records.
    @Test func entryLimitStopsTraversalBeforeExaminingEveryDescendant() throws {
        let directory = try fixtureDirectory("entry-limit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sub = directory.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("inner fortune\n".utf8).write(to: sub.appendingPathComponent("inner"))
        try Data("ignored\n".utf8).write(to: directory.appendingPathComponent("index.dat"))
        try Data("root fortune\n".utf8).write(to: directory.appendingPathComponent("quotes"))

        let limits = FortuneDatabase.Limits(maxFileBytes: 1_000_000, maxAggregateBytes: 1_000_000,
                                            maxRetainedRecords: 1_000, maxExaminedEntries: 3)
        let database = FortuneDatabase.load(directories: [directory], options: .init(), limits: limits)

        #expect(database.statistics.entriesExamined == 3)
        #expect(database.statistics.entryLimitReached)
    }

    /// Proves traversal never advances past the entry budget, regardless of how large
    /// the real directory is: an observer counts every attempt to advance the underlying
    /// `FileManager` enumerator. With a cap of 5 and 500 real files, only 6 attempts are
    /// ever made — one per admitted entry, plus the one that discovers the 6th exists and
    /// trips the cap — never anywhere close to the other ~494.
    @Test func entryBudgetNeverAdvancesPastItsCapRegardlessOfDirectorySize() throws {
        let directory = try fixtureDirectory("entry-budget-seam")
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0 ..< 500 {
            try Data("x\n".utf8).write(to: directory.appendingPathComponent("file\(index)"))
        }

        let limits = FortuneDatabase.Limits(maxFileBytes: 1_000_000, maxAggregateBytes: 1_000_000,
                                            maxRetainedRecords: 1_000, maxExaminedEntries: 5)
        var fetchAttempts = 0
        let database = FortuneDatabase.load(
            directories: [directory], options: .init(), limits: limits,
            entryFetchObserver: { fetchAttempts += 1 }
        )

        #expect(database.statistics.entriesExamined == 5)
        #expect(database.statistics.entryLimitReached)
        #expect(fetchAttempts == 6, "got \(fetchAttempts)")
    }

    /// A root with no `excluded.txt` anywhere must not be charged for a synthetic
    /// existence probe: exclusion discovery only counts real descendants traversal
    /// actually yields.
    @Test func exclusionDiscoveryDoesNotChargeForANonexistentCandidate() throws {
        let directory = try fixtureDirectory("exclusion-no-probe")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("only\n".utf8).write(to: directory.appendingPathComponent("quotes"))

        let database = FortuneDatabase.load(directories: [directory])
        #expect(database.statistics.entriesExamined == 1,
                "only the real 'quotes' file; no excluded.txt probe")
    }

    /// Real root-level and one-level-deep `excluded.txt` files are each counted exactly
    /// once as the real descendants they are — not probed twice, not walked twice — and
    /// both still apply to fortunes from anywhere in the root.
    @Test func exclusionDiscoveryChargesExactlyTheRealRootAndOneLevelDeepFiles() throws {
        let directory = try fixtureDirectory("exclusion-real-charge")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = Fortune.identifier(for: "remove me")
        try Data((target + "\n").utf8).write(to: directory.appendingPathComponent("excluded.txt"))
        let sub = directory.appendingPathComponent("collection")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let target2 = Fortune.identifier(for: "remove me too")
        try Data((target2 + "\n").utf8).write(to: sub.appendingPathComponent("excluded.txt"))
        try Data("keep me\n%\nremove me\n%\nremove me too\n".utf8)
            .write(to: sub.appendingPathComponent("quotes"))

        let database = FortuneDatabase.load(directories: [directory])
        // 4 real descendants: root excluded.txt, "collection" dir, its excluded.txt, its quotes.
        #expect(database.statistics.entriesExamined == 4)
        #expect(database.fortunes.map(\.text) == ["keep me"])
    }

    // MARK: Unreadable and invalid content

    /// Neither an unreadable file nor invalid UTF-8 should fail the load; both are counted
    /// and named without echoing the file's own content back.
    @Test func invalidUTF8AndUnreadableFilesAreSkippedWithContentSafeReasons() throws {
        let directory = try fixtureDirectory("unreadable-invalid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidPath = directory.appendingPathComponent("a-invalid")
        try Data([0xFF, 0xFE, 0x00]).write(to: invalidPath)
        let unreadablePath = directory.appendingPathComponent("b-unreadable")
        try Data("would be a fortune\n".utf8).write(to: unreadablePath)
        try Data("still loads\n".utf8).write(to: directory.appendingPathComponent("c-valid"))

        let database = FortuneDatabase.load(
            directories: [directory], options: .init(), limits: .production,
            reader: { path, maxBytes in
                // Compared by last component rather than the full path: `load()` walks
                // from a `resourceValues`-standardized URL, which need not be byte-for-byte
                // identical to this fixture's own construction of the same file's path.
                (path as NSString).lastPathComponent == "b-unreadable"
                    ? nil : FileManager.default.contents(atPath: path)?.prefix(maxBytes)
            }
        )

        #expect(database.statistics.invalidUTF8FilesSkipped == 1)
        #expect(database.statistics.unreadableFilesSkipped == 1)
        #expect(database.fortunes.map(\.text) == ["still loads"])
        #expect(database.issues.contains { $0.contains("a-invalid") && $0.contains("invalid UTF-8") })
        #expect(database.issues.contains { $0.contains("b-unreadable") && $0.contains("unreadable") })
        #expect(database.issues.allSatisfy { !$0.contains("would be a fortune") })
    }

    // MARK: Symbolic links and exclusion-list recovery diagnostics

    /// A symbolic link is never followed, whether it stands in for a candidate file, a
    /// directory, or a whole search root — its target's content never appears — and each
    /// kind produces its own content-safe detail in the authoritative sequence, not just
    /// a bare count.
    @Test func symlinkEventsAppearAsContentSafeDetailsAtFileDirectoryAndRootLevel() throws {
        let root = try fixtureDirectory("symlink-detail-root")
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try fixtureDirectory("symlink-detail-outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside secret\n".utf8).write(to: outside.appendingPathComponent("secret"))

        let usableRoot = root.appendingPathComponent("usable")
        try FileManager.default.createDirectory(at: usableRoot, withIntermediateDirectories: true)
        try Data("real fortune\n".utf8).write(to: usableRoot.appendingPathComponent("real"))
        try FileManager.default.createSymbolicLink(
            at: usableRoot.appendingPathComponent("linked-file"),
            withDestinationURL: outside.appendingPathComponent("secret")
        )
        try FileManager.default.createSymbolicLink(
            at: usableRoot.appendingPathComponent("linked-dir"), withDestinationURL: outside
        )

        let linkedRoot = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)

        let database = FortuneDatabase.load(directories: [usableRoot, linkedRoot])

        #expect(database.fortunes.map(\.text) == ["real fortune"])
        #expect(database.statistics.symbolicLinksSkipped == 3,
                "the linked file and linked directory below usableRoot, plus the linked root itself")
        #expect(database.issues.contains { $0.contains("linked-file") && $0.contains("symbolic link") })
        #expect(database.issues.contains { $0.contains("linked-dir") && $0.contains("symbolic link") })
        #expect(database.issues.contains {
            $0.contains("linked-root") && $0.contains("symbolic-link root")
        })
        #expect(database.issues.allSatisfy { !$0.contains("outside secret") })
    }

    /// Exclusion-list discovery obeys the same per-file and aggregate caps as fortune
    /// data, but a list within those caps still suppresses its identifier normally.
    @Test func exclusionListsObeyFileAndAggregateLimitsWithoutChangingValidBehavior() throws {
        let target = Fortune.identifier(for: "remove me")
        let quotesContent = "keep me\n%\nremove me\n"

        let oversizedRoot = try fixtureDirectory("exclusion-oversized")
        defer { try? FileManager.default.removeItem(at: oversizedRoot) }
        try Data(quotesContent.utf8).write(to: oversizedRoot.appendingPathComponent("quotes"))
        try Data((target + "\n# padding so this exclusion list exceeds the per-file cap\n").utf8)
            .write(to: oversizedRoot.appendingPathComponent("excluded.txt"))
        let tightLimits = FortuneDatabase.Limits(
            maxFileBytes: Data(quotesContent.utf8).count, maxAggregateBytes: 1_000_000,
            maxRetainedRecords: 1_000, maxExaminedEntries: 1_000
        )
        let oversizedDatabase = FortuneDatabase.load(directories: [oversizedRoot], options: .init(),
                                                      limits: tightLimits)
        #expect(oversizedDatabase.statistics.oversizedFilesSkipped == 1)
        #expect(Set(oversizedDatabase.fortunes.map(\.text)) == ["keep me", "remove me"],
                "the oversized exclusion list was skipped, so it suppressed nothing")

        let validRoot = try fixtureDirectory("exclusion-valid")
        defer { try? FileManager.default.removeItem(at: validRoot) }
        try Data(quotesContent.utf8).write(to: validRoot.appendingPathComponent("quotes"))
        try Data((target + "\n").utf8).write(to: validRoot.appendingPathComponent("excluded.txt"))
        let validDatabase = FortuneDatabase.load(directories: [validRoot], options: .init(),
                                                  limits: .production)
        #expect(validDatabase.fortunes.map(\.text) == ["keep me"])
    }

    /// An oversized, an invalid-UTF-8, and an unreadable exclusion list each produce
    /// their own content-safe detail — not just a counter — and none of them blocks
    /// ordinary fortune loading in the same root.
    @Test func exclusionListRecoveryEventsProduceContentSafeDetailsWithoutBlockingOrdinaryLoading() throws {
        let oversizedRoot = try fixtureDirectory("exclusion-detail-oversized")
        defer { try? FileManager.default.removeItem(at: oversizedRoot) }
        try Data(String(repeating: "#", count: 40).utf8)
            .write(to: oversizedRoot.appendingPathComponent("excluded.txt"))
        try Data("hello\n".utf8).write(to: oversizedRoot.appendingPathComponent("quotes"))
        let tightLimits = FortuneDatabase.Limits(maxFileBytes: 8, maxAggregateBytes: 1_000_000,
                                                 maxRetainedRecords: 1_000, maxExaminedEntries: 1_000)
        let oversizedDatabase = FortuneDatabase.load(directories: [oversizedRoot], options: .init(),
                                                      limits: tightLimits)
        #expect(oversizedDatabase.statistics.oversizedFilesSkipped == 1)
        #expect(oversizedDatabase.issues.contains {
            $0.contains("excluded.txt") && $0.contains("exclusion list") && $0.contains("larger than")
        })
        #expect(oversizedDatabase.fortunes.map(\.text) == ["hello"])

        let invalidRoot = try fixtureDirectory("exclusion-detail-invalid")
        defer { try? FileManager.default.removeItem(at: invalidRoot) }
        try Data([0xFF, 0xFE]).write(to: invalidRoot.appendingPathComponent("excluded.txt"))
        try Data("world\n".utf8).write(to: invalidRoot.appendingPathComponent("quotes"))
        let invalidDatabase = FortuneDatabase.load(directories: [invalidRoot])
        #expect(invalidDatabase.statistics.invalidUTF8FilesSkipped == 1)
        #expect(invalidDatabase.issues.contains {
            $0.contains("excluded.txt") && $0.contains("exclusion list") && $0.contains("invalid UTF-8")
        })
        #expect(invalidDatabase.fortunes.map(\.text) == ["world"])

        let unreadableRoot = try fixtureDirectory("exclusion-detail-unreadable")
        defer { try? FileManager.default.removeItem(at: unreadableRoot) }
        try Data("anything\n".utf8).write(to: unreadableRoot.appendingPathComponent("excluded.txt"))
        try Data("kept\n".utf8).write(to: unreadableRoot.appendingPathComponent("quotes"))
        let unreadableDatabase = FortuneDatabase.load(
            directories: [unreadableRoot], options: .init(), limits: .production,
            reader: { path, maxBytes in
                (path as NSString).lastPathComponent == "excluded.txt"
                    ? nil : FileManager.default.contents(atPath: path)?.prefix(maxBytes)
            }
        )
        #expect(unreadableDatabase.statistics.unreadableFilesSkipped == 1)
        #expect(unreadableDatabase.issues.contains {
            $0.contains("excluded.txt") && $0.contains("exclusion list") && $0.contains("unreadable")
        })
        #expect(unreadableDatabase.fortunes.map(\.text) == ["kept"])
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
    func smallCorporaRespectTheClampedHistoryAndStillTerminate(size: Int) {
        var selector = NoRepeatSelector(elements: Array(fortunes.prefix(size)),
                                        historyLimit: 20, seed: 3)
        let expectedHistorySize = max(0, size - 1)
        var recent: [String] = []
        for _ in 0 ..< 20 {
            guard let next = selector.next()?.text else { return #expect(Bool(false)) }
            #expect(!recent.contains(next))
            recent.append(next)
            while recent.count > expectedHistorySize { recent.removeFirst() }
        }
    }

    @Test func emptyCorpusYieldsNil() {
        var selector = NoRepeatSelector(elements: [Fortune](), seed: 1)
        #expect(selector.next() == nil)
    }

    @Test func uniformRecordModeIgnoresSourceSizesAndByteCounts() {
        let database = FortuneDatabase(
            fortunes: [
                Fortune(text: "a0", source: "a"),
                Fortune(text: "a1", source: "a"),
                Fortune(text: "a2", source: "a"),
                Fortune(text: "b0", source: "b"),
            ],
            weights: ["a": Int.max, "b": 1]
        )
        let rolls = [0.0, 0.24, 0.25, 0.49, 0.5, 0.74, 0.75, 0.99]
        var selector = NoRepeatSelector(database: database, historyLimit: 0,
                                        seed: 11, weightByFile: false,
                                        controlledRolls: rolls)

        let picks = rolls.compactMap { _ in selector.next()?.text }
        #expect(picks == ["a0", "a0", "a1", "a1", "a2", "a2", "b0", "b0"])
    }

    @Test func equalSourceModeSplitsEachSourcesShareAmongItsRecords() {
        let fortunes = [
            Fortune(text: "a0", source: "a"),
            Fortune(text: "a1", source: "a"),
            Fortune(text: "b0", source: "b"),
        ]
        let rolls = [0.0, 0.0, 0.49, 0.75, 0.5, 0.99]
        let expected = ["a0", "a1", "b0", "b0"]
        let byteCounts: [[String: Int]] = [
            ["a": 1, "b": Int.max],
            ["a": Int.max, "b": 1],
        ]

        for weights in byteCounts {
            let database = FortuneDatabase(fortunes: fortunes, weights: weights)
            var selector = NoRepeatSelector(database: database, historyLimit: 0,
                                            seed: 1, weightByFile: true,
                                            controlledRolls: rolls)
            let picks = (0 ..< expected.count).compactMap { _ in selector.next()?.text }
            #expect(picks == expected)
        }
    }

    @Test func equalSourceModeExcludesAndReadmitsAWhollyRecentSource() {
        let database = FortuneDatabase(fortunes: [
            Fortune(text: "a0", source: "a"),
            Fortune(text: "a1", source: "a"),
            Fortune(text: "b0", source: "b"),
        ])
        var selector = NoRepeatSelector(database: database, historyLimit: 2,
                                        seed: 1, weightByFile: true,
                                        controlledRolls: [0.0, 0.0, 0.0])

        let picks = (0 ..< 4).compactMap { _ in selector.next()?.text }
        #expect(picks == ["a0", "a1", "b0", "a0"])
    }

    @Test func weightedHistoryRenormalizesEqualAlternativesWithoutArrayBias() {
        let elements = ["dominant", "first", "second"]
        var lowerRoll = NoRepeatSelector(elements: elements, historyLimit: 1, seed: 1,
                                         weights: [Int.max, 1, 1],
                                         controlledRolls: [0.0, 0.25])
        var upperRoll = NoRepeatSelector(elements: elements, historyLimit: 1, seed: 1,
                                         weights: [Int.max, 1, 1],
                                         controlledRolls: [0.0, 0.75])

        #expect(lowerRoll.next() == "dominant")
        #expect(lowerRoll.next() == "first")
        #expect(upperRoll.next() == "dominant")
        #expect(upperRoll.next() == "second")
    }

    @Test func weightedModeUsesOnlyEligiblePositiveWeights() {
        let elements = ["two", "three", "zero", "negative"]
        let rolls = [0.0, 0.39, 0.41, 0.99]
        var selector = NoRepeatSelector(elements: elements, historyLimit: 0, seed: 1,
                                        weights: [2, 3, 0, -1],
                                        controlledRolls: rolls)

        let picks = rolls.compactMap { _ in selector.next() }
        #expect(picks == ["two", "two", "three", "three"])
    }

    @Test func weightedModeRecoversUniformlyWhenAllPositiveWeightsAreRecent() {
        let elements = ["positive", "zero", "negative"]
        var lowerRoll = NoRepeatSelector(elements: elements, historyLimit: 1, seed: 1,
                                         weights: [1, 0, -1],
                                         controlledRolls: [0.0, 0.0])
        var upperRoll = NoRepeatSelector(elements: elements, historyLimit: 1, seed: 1,
                                         weights: [1, 0, -1],
                                         controlledRolls: [0.0, 0.75])

        #expect(lowerRoll.next() == "positive")
        #expect(lowerRoll.next() == "zero")
        #expect(upperRoll.next() == "positive")
        #expect(upperRoll.next() == "negative")
    }

    @Test func invalidWeightArraysRecoverToUniformSelection() {
        let elements = ["first", "second", "third"]
        var absent = NoRepeatSelector(elements: elements, historyLimit: 0, seed: 1,
                                      controlledRolls: [0.1])
        var mismatched = NoRepeatSelector(elements: elements, historyLimit: 0, seed: 1,
                                          weights: [Int.max], controlledRolls: [0.8])
        var nonPositive = NoRepeatSelector(elements: elements, historyLimit: 0, seed: 1,
                                           weights: [0, -1, Int.min],
                                           controlledRolls: [0.4])

        #expect(absent.next() == "first")
        #expect(mismatched.next() == "third")
        #expect(nonPositive.next() == "second")
    }

    @Test func duplicateTextInDistinctRecordsRemainsDistinct() {
        let database = FortuneDatabase(
            fortunes: [
                Fortune(text: "same", source: "a"),
                Fortune(text: "same", source: "b"),
            ],
            weights: ["a": Int.max, "b": 1]
        )
        var selector = NoRepeatSelector(database: database, historyLimit: 0,
                                        seed: 1, weightByFile: false,
                                        controlledRolls: [0.0, 0.5])

        let picks = (0 ..< 2).compactMap { _ in selector.next() }
        #expect(picks.map(\.text) == ["same", "same"])
        #expect(picks.map(\.source) == ["a", "b"])
    }

    @Test func extremeIntegerWeightsDoNotOverflow() {
        var selector = NoRepeatSelector(elements: ["first", "second", "excluded"],
                                        historyLimit: 0, seed: 1,
                                        weights: [Int.max, Int.max, Int.min],
                                        controlledRolls: [0.25, 0.75])

        #expect(selector.next() == "first")
        #expect(selector.next() == "second")
    }
}
