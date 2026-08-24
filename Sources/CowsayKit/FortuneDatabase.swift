import Foundation

public struct Fortune: Equatable, Sendable {
    public let text: String
    /// The root-qualified file identity, used for `weightByFile` selection and diagnostics.
    public let source: String

    public init(text: String, source: String) {
        self.text = text
        self.source = source
    }

    /// A stable identifier for this exact quote.
    ///
    /// Derived from normalized text alone, so it is stable when a collection is renamed or
    /// reordered. Curation and optional `excluded.txt` lists use this identifier to refer to
    /// a specific quotation.
    public var id: String { Fortune.identifier(for: text) }

    public static func identifier(for text: String) -> String {
        let normalised = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hex(Array(normalised.utf8), prefixLength: 16)
    }
}

public struct FortuneLoadOptions: Sendable {
    /// How tall a record may be, in wrapped lines. `0` means no limit.
    ///
    /// Lines are the relevant display unit: records with equal character counts can occupy
    /// very different screen heights after wrapping.
    ///
    /// Measured at `wrapColumns`, which is the *narrowest* width the renderer will use, so
    /// this is a worst case: adaptive wrapping only ever makes a record shorter than this.
    public var maxLines: Int = 60
    /// The width `maxLines` is measured at. Kept in step with `Configuration.wrapWidth`.
    public var wrapColumns: Int = 40
    /// See `FortuneDatabase.isSafe(_:)` for what this actually filters and why.
    public var filterUnsafeCharacters: Bool = true

    public init(maxLines: Int = 60, wrapColumns: Int = 40,
                filterUnsafeCharacters: Bool = true) {
        self.maxLines = maxLines
        self.wrapColumns = wrapColumns
        self.filterUnsafeCharacters = filterUnsafeCharacters
    }
}

/// Parses fortune's plain-text database format: records separated by a line containing
/// only `%`.
///
/// Cowsaver scans text files directly and does not read fortune's binary `.dat` indexes.
public struct FortuneDatabase: Sendable {
    public struct Statistics: Sendable, Equatable {
        public var filesRead = 0
        /// Compatibility exclusions and fortune data files skipped during recovery. An
        /// `off` directory counts once because its descendants are deliberately not examined;
        /// the more specific `*Skipped` counters classify recovery cases.
        public var filesSkipped = 0
        public var droppedTooTall = 0
        public var droppedUnsafe = 0
        /// Records suppressed by an `excluded.txt` list.
        public var droppedExcluded = 0

        /// A candidate exceeded the per-file byte cap before or during its bounded read
        /// and was not decoded.
        public var oversizedFilesSkipped = 0
        /// A filesystem item could not be inspected or an eligible file could not be read.
        public var unreadableFilesSkipped = 0
        /// A candidate read successfully but was not valid UTF-8.
        public var invalidUTF8FilesSkipped = 0
        /// A symbolic-link root, directory, or file. Links are never followed; descendant
        /// links count as examined entries, while root checks do not.
        public var symbolicLinksSkipped = 0

        /// Filesystem entries this load examined: every file, directory, and symbolic
        /// link that traversal or exclusion-list discovery looked at, bounded by
        /// `Limits.maxExaminedEntries`.
        public var entriesExamined = 0
        /// Set when the examined-entry cap ended traversal before every root was fully walked.
        public var entryLimitReached = false
        /// Set when the aggregate-byte cap ended reading before every eligible file was read.
        public var aggregateByteLimitReached = false
        /// Set when the retained-record cap ended parsing before every eligible record was kept.
        public var recordLimitReached = false

        public init(filesRead: Int = 0, filesSkipped: Int = 0,
                    droppedTooTall: Int = 0, droppedUnsafe: Int = 0,
                    droppedExcluded: Int = 0,
                    oversizedFilesSkipped: Int = 0, unreadableFilesSkipped: Int = 0,
                    invalidUTF8FilesSkipped: Int = 0, symbolicLinksSkipped: Int = 0,
                    entriesExamined: Int = 0, entryLimitReached: Bool = false,
                    aggregateByteLimitReached: Bool = false, recordLimitReached: Bool = false) {
            self.filesRead = filesRead
            self.filesSkipped = filesSkipped
            self.droppedTooTall = droppedTooTall
            self.droppedUnsafe = droppedUnsafe
            self.droppedExcluded = droppedExcluded
            self.oversizedFilesSkipped = oversizedFilesSkipped
            self.unreadableFilesSkipped = unreadableFilesSkipped
            self.invalidUTF8FilesSkipped = invalidUTF8FilesSkipped
            self.symbolicLinksSkipped = symbolicLinksSkipped
            self.entriesExamined = entriesExamined
            self.entryLimitReached = entryLimitReached
            self.aggregateByteLimitReached = aggregateByteLimitReached
            self.recordLimitReached = recordLimitReached
        }
    }

    /// Fixed bounds on one `load()` call's filesystem work, memory retention, and
    /// diagnostic volume.
    ///
    /// These are package behavior, not user settings. They keep an oversized or adversarial
    /// personal collection from stalling initialization or growing retained memory without
    /// bound. Tests exercise the boundaries through an internal overload with smaller values
    /// rather than constructing production-sized fixtures for every case.
    struct Limits: Sendable, Equatable {
        var maxFileBytes: Int
        var maxAggregateBytes: Int
        var maxRetainedRecords: Int
        var maxExaminedEntries: Int

        static let production = Limits(
            maxFileBytes: 8 * 1024 * 1024,
            maxAggregateBytes: 32 * 1024 * 1024,
            maxRetainedRecords: 100_000,
            maxExaminedEntries: 1_000
        )
    }

    public private(set) var fortunes: [Fortune]
    public private(set) var statistics: Statistics
    /// Raw byte count per source file, retained as loading metadata.
    public private(set) var weights: [String: Int]
    /// Bounded, content-safe descriptions of loader recovery events, named by standardized
    /// source path. `statistics` keeps complete counts even past the detail cap a caller
    /// applies when logging these.
    public private(set) var issues: [String]

    public var isEmpty: Bool { fortunes.isEmpty }

    public init(fortunes: [Fortune] = [], statistics: Statistics = .init(),
                weights: [String: Int] = [:], issues: [String] = []) {
        self.fortunes = fortunes
        self.statistics = statistics
        self.weights = weights
        self.issues = issues
    }

    /// Returns the compiled-in fallback fortunes.
    public static func builtIn() -> FortuneDatabase {
        let fortunes = BuiltIn.fortunes.map { Fortune(text: $0, source: "built-in") }
        return FortuneDatabase(
            fortunes: fortunes,
            statistics: Statistics(filesRead: 1),
            weights: ["built-in": fortunes.reduce(0) { $0 + $1.text.utf8.count }]
        )
    }

    // MARK: - Parsing

    /// Split one file's contents into records.
    public static func parse(
        contents: String,
        source: String,
        options: FortuneLoadOptions = .init(),
        excluded: Set<String> = [],
        statistics: inout Statistics
    ) -> [Fortune] {
        parse(contents: contents, source: source, options: options, excluded: excluded,
             statistics: &statistics, maxRecords: .max, lineObserver: nil)
    }

    /// `maxRecords` lets `load(directories:options:limits:)` stop retaining once the
    /// aggregate record cap is reached. The input is scanned by string index rather than
    /// split into an array of lines or records. Each record is filtered when its terminating
    /// `%` (or end of input) is reached, and no later record is scanned after the cap.
    ///
    /// `lineObserver`, when non-nil, is called once per line actually visited. It exists
    /// only so a focused test can prove that stop is real: the filtering counters alone
    /// cannot distinguish "a later record was never scanned" from "it was scanned and
    /// happened to be filtered out," so a test needs a seam that counts visits directly.
    ///
    /// The public `parse` above is unbounded, matching its existing direct-caller contract;
    /// only the internal loader needs the cap.
    static func parse(
        contents: String,
        source: String,
        options: FortuneLoadOptions,
        excluded: Set<String>,
        statistics: inout Statistics,
        maxRecords: Int,
        lineObserver: (() -> Void)? = nil
    ) -> [Fortune] {
        let normalised = contents.replacingOccurrences(of: "\r\n", with: "\n")

        var out: [Fortune] = []

        // Filters and, if eligible, retains one already-delimited record. Returns false
        // once the retained-record cap has been reached, telling the caller to stop
        // scanning further lines rather than assemble a record that will not be kept.
        func admit(_ record: Substring) -> Bool {
            guard out.count < maxRecords else {
                statistics.recordLimitReached = true
                return false
            }
            let text = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return true }
            if options.maxLines > 0,
               isTallerThan(options.maxLines, text: text, columns: options.wrapColumns) {
                statistics.droppedTooTall += 1
                return true
            }
            if options.filterUnsafeCharacters, !isSafe(text) {
                statistics.droppedUnsafe += 1
                return true
            }
            // Suppress records listed by the collection's optional excluded.txt file.
            if !excluded.isEmpty, excluded.contains(Fortune.identifier(for: text)) {
                statistics.droppedExcluded += 1
                return true
            }
            out.append(Fortune(text: text, source: source))
            return true
        }

        guard maxRecords > 0 else {
            statistics.recordLimitReached = true
            return out
        }

        // Fortune files have no comment syntax. Consecutive leading `##` lines are
        // provenance metadata; `##` remains ordinary quote text after the first
        // non-metadata line. Finding each newline from the previous one keeps only the
        // source string and the current record range in memory.
        var lineStart = normalised.startIndex
        var recordStart: String.Index?
        var droppingLeadingMetadata = true

        while true {
            let newline = normalised[lineStart...].firstIndex(of: "\n")
            let lineEnd = newline ?? normalised.endIndex
            let line = normalised[lineStart ..< lineEnd]
            lineObserver?()

            if droppingLeadingMetadata, line.hasPrefix("##") {
                // The next line may still be provenance metadata.
            } else {
                if droppingLeadingMetadata {
                    droppingLeadingMetadata = false
                    recordStart = lineStart
                }

                if line == "%" {
                    guard admit(normalised[(recordStart ?? lineStart) ..< lineStart]) else {
                        return out
                    }
                    // A delimiter establishes that another record follows. Once this
                    // delimiter retained the last allowed record, stop before visiting
                    // even the first line of the next one.
                    if out.count >= maxRecords {
                        statistics.recordLimitReached = true
                        return out
                    }
                    recordStart = newline.map { normalised.index(after: $0) }
                        ?? normalised.endIndex
                }
            }

            guard let newline else { break }
            lineStart = normalised.index(after: newline)
        }

        if let recordStart {
            _ = admit(normalised[recordStart ..< normalised.endIndex])
        } else {
            _ = admit(normalised[normalised.endIndex ..< normalised.endIndex])
        }
        return out
    }

    /// How many lines a record wraps to at `columns`.
    ///
    /// Uses the real wrapper rather than dividing by the width, because the two disagree
    /// often enough to matter: `fill` reflows paragraphs and collapses whitespace, so an
    /// estimate would reject records the renderer would have handled fine.
    static func wrappedLineCount(_ text: String, columns: Int) -> Int {
        WordWrap.fill(Message.linesFromStdin(Bytes.from(text)), columns: columns).count
    }

    /// Whether a record is taller than `maxLines` when wrapped at `columns`.
    ///
    /// A cheap upper bound avoids full wrapping for records that certainly fit. When the
    /// bound exceeds the limit, the exact wrapper decides.
    ///
    /// The bound must not underestimate. Greedy wrapping may create a short line before a
    /// word that then occupies full-width lines, so it allows twice the naïve byte-to-width
    /// estimate plus paragraph overhead. Whitespace collapsing can only reduce the result.
    /// Tests check the bound against the exact wrapper for the bundled corpus and adversarial
    /// inputs.
    static func isTallerThan(_ maxLines: Int, text: String, columns: Int) -> Bool {
        if upperBoundOnLines(text, columns: columns) <= maxLines { return false }
        return wrappedLineCount(text, columns: columns) > maxLines
    }

    static func upperBoundOnLines(_ text: String, columns: Int) -> Int {
        let width = max(columns - 1, 1)
        let bytes = Array(text.utf8)

        // Paragraphs follow WordWrap's rule: a newline followed by whitespace. A bare
        // newline is reflowed into a space and does not begin a new paragraph.
        var paragraphs = 1
        for i in 0 ..< max(bytes.count - 1, 0)
        where bytes[i] == Bytes.lf && Bytes.isSpace(bytes[i + 1]) {
            paragraphs += 1
        }

        return 2 * ((bytes.count + width - 1) / width) + 4 * paragraphs + 2
    }

    /// Records are filtered for safety rather than measured for display width.
    ///
    /// cowsay wraps by byte count, so a boundary can split a multi-byte character and produce
    /// invalid UTF-8. The screensaver filters non-ASCII records before rendering; statistics
    /// record how many entries were excluded.
    public static func isSafe(_ text: String) -> Bool {
        text.utf8.allSatisfy { byte in
            (byte >= 0x20 && byte <= 0x7E) || byte == 0x0A || byte == 0x09
        }
    }

    // MARK: - Loading

    /// Load every eligible fortune file in the given directories, subject to
    /// `Limits.production`.
    ///
    /// Unreadable, invalid, oversized, and symbolic-link candidates are counted and
    /// skipped rather than causing the load to fail.
    public static func load(
        directories: [URL],
        options: FortuneLoadOptions = .init()
    ) -> FortuneDatabase {
        load(directories: directories, options: options, limits: .production)
    }

    /// Running totals for one `load()` call. A reference type so the walk and its
    /// per-candidate helpers can update one set of counters without threading a long
    /// `inout` parameter list; it never escapes the `load()` call that creates it.
    /// Internal rather than private so focused tests can drive its bounded-read logic
    /// directly with injected `Limits`.
    final class LoadBudget {
        let limits: Limits
        var statistics = Statistics()
        var issues: [String] = []
        private var aggregateBytesRead = 0
        private(set) var retainedCount = 0

        init(limits: Limits) { self.limits = limits }

        /// Any exhausted cap stops all further load work, in every root — not just the
        /// directory or file being looked at when it tripped.
        var shouldStop: Bool {
            statistics.entryLimitReached || statistics.aggregateByteLimitReached
                || statistics.recordLimitReached
        }

        var recordBudgetRemaining: Int { max(0, limits.maxRetainedRecords - retainedCount) }

        func retain(_ count: Int) { retainedCount += count }

        /// Registers one more examined filesystem entry. Every descendant traversal
        /// actually yields consumes one, including ignored metadata and rejected
        /// candidates: the cap bounds *examination*, not just parsing, so a directory
        /// full of unusable files cannot be walked forever. A path this load merely
        /// probes and finds absent (a candidate exclusion list that does not exist) is
        /// not a descendant traversal encountered and must not call this.
        func consumeEntry() -> Bool {
            guard statistics.entriesExamined < limits.maxExaminedEntries else {
                statistics.entryLimitReached = true
                return false
            }
            statistics.entriesExamined += 1
            return true
        }

        /// The outcome of trying to read one candidate's bytes.
        enum ReadOutcome {
            case success(Data)
            case unreadable
            case overPerFileCap
            case overAggregateCap
        }

        /// Reads at most the admitted number of bytes for one candidate, never trusting
        /// `statedSize` for anything beyond an initial fast rejection of an obviously
        /// oversized file: the file can still grow between that metadata read and this
        /// one, so only the *actual* bytes `reader` returns decide the outcome and get
        /// charged to the aggregate cap. An unreadable or over-cap result charges
        /// nothing and is never decoded; the reader retains at most the one-byte
        /// lookahead needed to distinguish an exact boundary from an oversized file.
        func readBounded(
            atPath path: String, statedSize: Int?, reader: (String, Int) -> Data?
        ) -> ReadOutcome {
            guard let statedSize else { return .unreadable }
            guard statedSize <= limits.maxFileBytes else { return .overPerFileCap }

            let aggregateRemaining = max(0, limits.maxAggregateBytes - aggregateBytesRead)
            let boundedLimit = min(limits.maxFileBytes, aggregateRemaining)
            // One byte past the bound is enough to prove "exceeds" without ever reading
            // a much larger file fully into memory.
            let readLimit = boundedLimit == Int.max ? Int.max : boundedLimit + 1
            guard let data = reader(path, readLimit) else { return .unreadable }
            if data.count > limits.maxFileBytes {
                return .overPerFileCap
            }
            if data.count > aggregateRemaining {
                statistics.aggregateByteLimitReached = true
                return .overAggregateCap
            }

            // Actual bytes, never metadata: this cannot fail, since data.count <=
            // boundedLimit <= aggregateRemaining by construction, but it is routed
            // through the same overflow-checked accumulator as everything else so there
            // is exactly one place that ever adds to the aggregate total.
            _ = reserveAggregateBytes(data.count)
            return .success(data)
        }

        /// Reserves `size` actual bytes against the aggregate cap. The addition remains
        /// overflow-checked even though callers admit only bounded read results.
        func reserveAggregateBytes(_ size: Int) -> Bool {
            let (sum, overflowed) = aggregateBytesRead.addingReportingOverflow(size)
            guard !overflowed, sum <= limits.maxAggregateBytes else {
                statistics.aggregateByteLimitReached = true
                return false
            }
            aggregateBytesRead = sum
            return true
        }

        func addDetail(_ text: String) {
            issues.append(text)
        }
    }

    /// Collects bounded chunks. Clean EOF returns the bytes accumulated so far; any read
    /// error rejects the entire candidate rather than treating a partial prefix as a file.
    static func collectBoundedData(
        maxBytes: Int, readChunk: (Int) throws -> Data?
    ) -> Data? {
        var data = Data()
        do {
            while data.count < maxBytes {
                let remaining = maxBytes - data.count
                guard let chunk = try readChunk(remaining), !chunk.isEmpty else { break }
                guard chunk.count <= remaining else { return nil }
                data.append(chunk)
            }
            return data
        } catch {
            return nil
        }
    }

    /// The production byte reader opens the file and collects at most `maxBytes`, so a
    /// file's true size does not control how much memory one call allocates.
    private static func boundedFileReader(atPath path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return collectBoundedData(maxBytes: maxBytes) { remaining in
            try handle.read(upToCount: remaining)
        }
    }

    /// Parses `excluded.txt` line syntax: one stable Fortune identifier per line, with an
    /// optional trailing comment; blank lines and lines starting with `#` are ignored.
    private static func exclusionIdentifiers(in text: String) -> Set<String> {
        var identifiers: Set<String> = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            // "<id>   # reason" — take the first field.
            let identifier = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first.map(String.init) ?? trimmed
            if identifier.count >= 8 { identifiers.insert(identifier.lowercased()) }
        }
        return identifiers
    }

    /// Documentation and metadata that live alongside the data and must never be parsed
    /// as quotes.
    static let metadataFilenames: Set<String> = [
        "LICENSE", "COPYING", "README", "NOTES", "CREDITS", "MANIFEST", "PROVENANCE",
    ]

    /// `reader` stands in for reading a candidate's bytes, bounded to at most the given
    /// number of bytes. Production code never overrides it; tests use it as a
    /// deterministic seam — for an unreadable path, or for simulating a file whose actual
    /// content differs from its stated metadata size — that does not depend on chmod
    /// (whose effect differs for a privileged test-running user) or on constructing a
    /// real multi-gigabyte fixture.
    ///
    /// `entryFetchObserver`, when non-nil, is called once per attempt to advance the
    /// underlying filesystem enumerator, whether or not it yields an item. It exists only
    /// so a focused test can prove traversal never advances past the entry budget: with a
    /// directory of many more entries than the injected cap, the observed call count must
    /// stay near the cap regardless of the directory's real size.
    static func load(
        directories: [URL],
        options: FortuneLoadOptions,
        limits: Limits,
        reader: (String, Int) -> Data? = boundedFileReader,
        entryFetchObserver: (() -> Void)? = nil
    ) -> FortuneDatabase {
        let budget = LoadBudget(limits: limits)
        var fortunes: [Fortune] = []
        var weights: [String: Int] = [:]
        let fm = FileManager.default
        let resourceKeyList: [URLResourceKey] = [
            .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey,
        ]
        let resourceKeySet = Set(resourceKeyList)

        for directory in ResourceLocations.standardizedDirectories(directories) {
            guard !budget.shouldStop else { break }

            // Root existence and symbolic-link checks do not consume an entry: they are
            // not descendants of anything traversal has entered yet. A symbolic-link
            // root is still a real recovery event, though, and is reported like any
            // other skipped symbolic link — just without spending the entry budget.
            guard let rootValues = try? directory.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isDirectoryKey]
            ) else { continue }
            if rootValues.isSymbolicLink == true {
                budget.statistics.symbolicLinksSkipped += 1
                budget.addDetail(
                    "\(directory.standardizedFileURL.path): symbolic-link root; skipped"
                )
                continue
            }
            guard rootValues.isDirectory == true else { continue }

            // One incremental filesystem walk per root. This code requests descendants
            // one at a time and neither accumulates nor sorts a directory listing. Once
            // the budget is exhausted it does not request another descendant, and the
            // diagnostic makes no ordering promise about unseen entries.
            //
            // Exclusion identifiers and eligible fortune bytes are collected together in
            // this single pass; parsing is deferred to the `pending` loop below so a
            // file admitted early is still filtered by a later sibling's `excluded.txt`,
            // preserving the root-plus-one-level-deep union semantics.
            guard let walker = fm.enumerator(
                at: directory, includingPropertiesForKeys: resourceKeyList, options: [],
                errorHandler: { _, _ in true }
            ) else { continue }

            var excluded: Set<String> = []
            // Everything buffered here was charged when read, so its source data cannot
            // exceed `Limits.maxAggregateBytes`. This preserves root-wide exclusions
            // without creating another unbounded retention point.
            var pending: [(source: String, contents: String, byteCount: Int)] = []

            while !budget.shouldStop {
                entryFetchObserver?()
                guard let child = walker.nextObject() as? URL else { break }
                guard budget.consumeEntry() else { break }

                guard let values = try? child.resourceValues(forKeys: resourceKeySet) else {
                    budget.statistics.unreadableFilesSkipped += 1
                    budget.addDetail(
                        "\(child.standardizedFileURL.path): metadata unavailable; skipped"
                    )
                    continue
                }

                // Symbolic-link status is checked first and unconditionally: a link is
                // never opened, never sized against the file cap, and never descended
                // into, whatever it names or points at.
                if values.isSymbolicLink == true {
                    budget.statistics.symbolicLinksSkipped += 1
                    budget.addDetail(
                        "\(child.standardizedFileURL.path): symbolic link; skipped"
                    )
                    walker.skipDescendants()
                    continue
                }

                let name = child.lastPathComponent
                if values.isDirectory == true {
                    // fortune-mod's convention for separately distributed content: a
                    // directory *component* exactly equal to "off" (not a name that
                    // merely contains it, like "handoff" or "office"). Pruned here,
                    // rather than filtered per-file after a full walk, so descendants
                    // are never examined at all and cannot spend the entry budget.
                    if name == "off" {
                        budget.statistics.filesSkipped += 1
                        walker.skipDescendants()
                    }
                    continue
                }

                guard values.isRegularFile == true else { continue }

                // Exclusion lists apply at the root and one level below it — exactly
                // enumerator levels 1 and 2 relative to this root — and are never
                // treated as fortune candidates even at a deeper, unhonored level, where
                // the ordinary dotted-name rule below already ignores them quietly.
                if name == "excluded.txt", walker.level <= 2 {
                    let source = child.standardizedFileURL.path
                    switch budget.readBounded(atPath: child.path, statedSize: values.fileSize,
                                              reader: reader) {
                    case .unreadable:
                        budget.statistics.unreadableFilesSkipped += 1
                        budget.addDetail("\(source): exclusion list unreadable; skipped")
                    case .overPerFileCap:
                        budget.statistics.oversizedFilesSkipped += 1
                        budget.addDetail(
                            "\(source): exclusion list larger than \(limits.maxFileBytes) "
                                + "bytes; skipped"
                        )
                    case .overAggregateCap:
                        break
                    case .success(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            excluded.formUnion(Self.exclusionIdentifiers(in: text))
                        } else {
                            budget.statistics.invalidUTF8FilesSkipped += 1
                            budget.addDetail(
                                "\(source): exclusion list invalid UTF-8; skipped"
                            )
                        }
                    }
                    continue
                }

                // Documentation and fortune's own binary indexes live alongside the
                // data and must stay quiet: they are intentionally ignored, not
                // recovered from, so traversal still counts them as examined but never
                // as skipped.
                if name.hasPrefix(".") || name.contains(".") { continue }
                if metadataFilenames.contains(name) { continue }
                // The filename half of the "off" convention.
                if name.hasSuffix("-o") {
                    budget.statistics.filesSkipped += 1
                    continue
                }

                guard budget.recordBudgetRemaining > 0 else {
                    budget.statistics.recordLimitReached = true
                    break
                }

                let source = child.standardizedFileURL.path
                switch budget.readBounded(atPath: child.path, statedSize: values.fileSize,
                                          reader: reader) {
                case .unreadable:
                    budget.statistics.unreadableFilesSkipped += 1
                    budget.statistics.filesSkipped += 1
                    budget.addDetail("\(source): unreadable; skipped")
                case .overPerFileCap:
                    budget.statistics.oversizedFilesSkipped += 1
                    budget.statistics.filesSkipped += 1
                    budget.addDetail("\(source): larger than \(limits.maxFileBytes) bytes; skipped")
                case .overAggregateCap:
                    break
                case .success(let data):
                    guard let contents = String(data: data, encoding: .utf8) else {
                        budget.statistics.invalidUTF8FilesSkipped += 1
                        budget.statistics.filesSkipped += 1
                        budget.addDetail("\(source): invalid UTF-8; skipped")
                        continue
                    }
                    // A relative filename is ambiguous across intended collections;
                    // the standardized root stays in the identity so each file owns
                    // its own weight.
                    pending.append((source: source, contents: contents, byteCount: data.count))
                }
            }

            // Exclusions for this root are only complete once its walk — or the cap
            // that cut it short — has finished, so buffered candidates are parsed and
            // filtered now, never before.
            for item in pending {
                guard budget.recordBudgetRemaining > 0 else {
                    budget.statistics.recordLimitReached = true
                    break
                }
                let parsed = parse(contents: item.contents, source: item.source, options: options,
                                   excluded: excluded, statistics: &budget.statistics,
                                   maxRecords: budget.recordBudgetRemaining)
                guard !parsed.isEmpty else { continue }
                budget.statistics.filesRead += 1
                weights[item.source] = item.byteCount
                fortunes += parsed
                budget.retain(parsed.count)
            }
        }

        return FortuneDatabase(fortunes: fortunes, statistics: budget.statistics,
                               weights: weights, issues: budget.issues)
    }
}
