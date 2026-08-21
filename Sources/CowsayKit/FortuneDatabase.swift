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
        public var filesSkipped = 0
        public var droppedTooTall = 0
        public var droppedUnsafe = 0
        /// Records suppressed by an `excluded.txt` list.
        public var droppedExcluded = 0

        public init(filesRead: Int = 0, filesSkipped: Int = 0,
                    droppedTooTall: Int = 0, droppedUnsafe: Int = 0,
                    droppedExcluded: Int = 0) {
            self.filesRead = filesRead
            self.filesSkipped = filesSkipped
            self.droppedTooTall = droppedTooTall
            self.droppedUnsafe = droppedUnsafe
            self.droppedExcluded = droppedExcluded
        }
    }

    public private(set) var fortunes: [Fortune]
    public private(set) var statistics: Statistics
    /// Bytes per source file, for `weightByFile` selection.
    public private(set) var weights: [String: Int]

    public var isEmpty: Bool { fortunes.isEmpty }

    public init(fortunes: [Fortune] = [], statistics: Statistics = .init(),
                weights: [String: Int] = [:]) {
        self.fortunes = fortunes
        self.statistics = statistics
        self.weights = weights
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
        let normalised = contents.replacingOccurrences(of: "\r\n", with: "\n")
        var records: [String] = []
        var current: [Substring] = []

        // Fortune files have no comment syntax. Cowsaver treats consecutive leading `##`
        // lines as provenance metadata; `##` remains ordinary quote text elsewhere.
        var lines = normalised.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let first = lines.first, first.hasPrefix("##") { lines = lines.dropFirst() }

        for line in lines {
            if line == "%" {
                records.append(current.joined(separator: "\n"))
                current = []
            } else {
                current.append(line)
            }
        }
        records.append(current.joined(separator: "\n"))

        var out: [Fortune] = []
        for record in records {
            let text = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if options.maxLines > 0,
               isTallerThan(options.maxLines, text: text, columns: options.wrapColumns) {
                statistics.droppedTooTall += 1
                continue
            }
            if options.filterUnsafeCharacters, !isSafe(text) {
                statistics.droppedUnsafe += 1
                continue
            }
            // Suppress records listed by the collection's optional excluded.txt file.
            if !excluded.isEmpty, excluded.contains(Fortune.identifier(for: text)) {
                statistics.droppedExcluded += 1
                continue
            }
            out.append(Fortune(text: text, source: source))
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

    /// Load every fortune file in the given directories.
    ///
    /// Unreadable files are counted and skipped.
    public static func load(
        directories: [URL],
        options: FortuneLoadOptions = .init()
    ) -> FortuneDatabase {
        var fortunes: [Fortune] = []
        var statistics = Statistics()
        var weights: [String: Int] = [:]
        let fm = FileManager.default

        for directory in ResourceLocations.standardizedDirectories(directories) {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let walker = fm.enumerator(atPath: directory.path) else { continue }

            let excluded = loadExclusions(in: directory)

            for case let relative as String in walker {
                let name = (relative as NSString).lastPathComponent
                // fortune's convention for separately distributed content: an `-o` suffix
                // or an `off/` directory. Skip those files.
                let isExcludedByConvention = name.hasSuffix("-o") || relative.contains("off/")

                // Fortune data files have no extension. Files with extensions are indexes or
                // adjacent metadata and are not quote sources.
                if name.hasPrefix(".") || name.contains(".") { continue }
                if metadataFilenames.contains(name) { continue }
                if isExcludedByConvention {
                    statistics.filesSkipped += 1
                    continue
                }

                let path = directory.appendingPathComponent(relative)
                var pathIsDirectory: ObjCBool = false
                guard fm.fileExists(atPath: path.path, isDirectory: &pathIsDirectory),
                      !pathIsDirectory.boolValue,
                      let data = fm.contents(atPath: path.path),
                      let contents = String(data: data, encoding: .utf8) else {
                    statistics.filesSkipped += 1
                    continue
                }

                // A relative filename is ambiguous across intended collections. Keep the
                // standardized root in the identity so each file owns its own weight.
                let source = path.standardizedFileURL.path
                let parsed = parse(contents: contents, source: source, options: options,
                                   excluded: excluded,
                                   statistics: &statistics)
                guard !parsed.isEmpty else { continue }
                statistics.filesRead += 1
                weights[source] = data.count
                fortunes += parsed
            }
        }

        return FortuneDatabase(fortunes: fortunes, statistics: statistics, weights: weights)
    }

    /// Documentation and metadata that live alongside the data and must never be parsed
    /// as quotes.
    static let metadataFilenames: Set<String> = [
        "LICENSE", "COPYING", "README", "NOTES", "CREDITS", "MANIFEST", "PROVENANCE",
    ]

    /// Read an `excluded.txt` list, if the directory has one.
    ///
    /// Each loaded collection may supply an exclusion list at its root or one directory
    /// below it. Entries are stable Fortune identifiers; comments and blank lines are ignored.
    static func loadExclusions(in directory: URL) -> Set<String> {
        var identifiers: Set<String> = []
        let fm = FileManager.default

        var candidates = [directory.appendingPathComponent("excluded.txt")]
        if let entries = try? fm.contentsOfDirectory(at: directory,
                                                     includingPropertiesForKeys: nil) {
            candidates += entries.map { $0.appendingPathComponent("excluded.txt") }
        }

        for candidate in candidates {
            guard let data = fm.contents(atPath: candidate.path),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                // "<id>   # reason" — take the first field.
                let identifier = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first.map(String.init) ?? trimmed
                if identifier.count >= 8 { identifiers.insert(identifier.lowercased()) }
            }
        }
        return identifiers
    }
}
