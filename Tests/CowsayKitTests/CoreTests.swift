import Testing
@testable import CowsayKit

// Unit tests for individual algorithms. GoldenTests verifies complete byte-for-byte output;
// these tests identify the underlying behavior when a compatibility case changes.

// MARK: - Word wrapping

@Suite("Word wrapping")
struct WordWrapTests {
    private func fill(_ text: String, columns: Int = 40) -> [String] {
        WordWrap.fill(Message.linesFromStdin(Bytes.from(text)), columns: columns)
            .map(Bytes.describe)
    }

    /// Text::Wrap reserves the final column, so `-W 40` yields lines of at most 39.
    @Test func wrapsAtColumnsMinusOne() {
        #expect(fill(String(repeating: "x", count: 39)) == [String(repeating: "x", count: 39)])
        #expect(fill(String(repeating: "x", count: 40))
                == [String(repeating: "x", count: 39), "x"])
    }

    /// `$huge = 'wrap'`: an over-long word is hard-broken rather than left to overflow.
    @Test func hardBreaksOverlongWord() {
        #expect(fill(String(repeating: "z", count: 90)) == [
            String(repeating: "z", count: 39),
            String(repeating: "z", count: 39),
            String(repeating: "z", count: 12),
        ])
    }

    /// `fill` collapses every whitespace run to one space. Tab *stops* belong to the `-n`
    /// path only.
    @Test(arguments: [("a\tb", "a b"), ("a\t\tb", "a b"), ("a   b", "a b"), ("\tab", " ab")])
    func collapsesWhitespaceRatherThanExpandingTabs(input: String, expected: String) {
        #expect(fill(input) == [expected])
    }

    @Test func expandTabsUsesEightColumnStops() {
        #expect(WordWrap.expandTabs([Bytes.from("a\tb")]).map(Bytes.describe) == ["a       b"])
    }

    /// Paragraphs reflow and are rejoined with a blank line, which becomes an empty
    /// padded row inside the balloon.
    @Test func paragraphsReflowAndKeepASeparatingBlankLine() {
        #expect(fill("line one\nline two\n\npara two here")
                == ["line one line two", "", "para two here"])
    }

    /// The paragraph split is `/\n\s+/`, so an indented line also starts a paragraph.
    @Test func indentedLineStartsANewParagraph() {
        #expect(fill("first\n  second") == ["first", "", "second"])
    }

    @Test func emptyInputProducesNoLines() {
        #expect(fill("").isEmpty)
    }

    /// Text::Wrap stops as soon as only break characters remain, and drops them. So a
    /// message of nothing but whitespace yields *no* lines — and therefore an empty
    /// balloon, not one containing a space.
    @Test(arguments: ["   ", "\t", "\r\n", "\n\n\n", " \t \t "])
    func allWhitespaceInputCollapsesToNothing(input: String) {
        #expect(fill(input).isEmpty)
    }

    /// Real cowsay lets `-W 1` reach Text::Wrap, which documents `$columns >= 2`, and it
    /// produces a degenerate balloon containing the literal string `0`. Cowsaver clamps
    /// widths below 2 to Text::Wrap's documented minimum.
    @Test func degenerateWidthIsClampedRatherThanReproduced() {
        #expect(fill("hello world foo", columns: 1) == fill("hello world foo", columns: 2))
    }
}

// MARK: - Balloon

@Suite("Balloon construction")
struct BalloonTests {
    private func balloon(_ lines: [String], mode: BalloonMode = .say) -> [String] {
        BalloonBuilder.build(lines.map(Bytes.from), mode: mode).lines.map(Bytes.describe)
    }

    @Test func singleLineUsesAngleBrackets() {
        #expect(balloon(["one"]) == [" _____", "< one >", " -----"])
    }

    /// Decided *after* wrapping: two lines already get corners, with no `|` rows.
    @Test func twoLinesUseCornersWithNoMiddleRow() {
        #expect(balloon(["aa", "b"]) == [" ____", "/ aa \\", "\\ b  /", " ----"])
    }

    @Test func threeLinesGetPipeMiddleRows() {
        #expect(balloon(["aa", "b", "cc"])
                == [" ____", "/ aa \\", "| b  |", "\\ cc /", " ----"])
    }

    /// Think mode is checked before the line count, so it never grows corners.
    @Test func thinkModeUsesParenthesesOnEveryRow() {
        #expect(balloon(["aa", "b", "cc"], mode: .think)
                == [" ____", "( aa )", "( b  )", "( cc )", " ----"])
    }

    @Test func emptyMessageStillProducesABalloon() {
        #expect(balloon([]) == [" __", "<  >", " --"])
    }

    @Test func thoughtsCharacterDiffersByMode() {
        #expect(BalloonBuilder.build([], mode: .say).thoughts == UInt8(ascii: "\\"))
        #expect(BalloonBuilder.build([], mode: .think).thoughts == UInt8(ascii: "o"))
    }
}

// MARK: - Faces

@Suite("Face modes")
struct FaceTests {
    @Test func defaultFace() {
        #expect(Bytes.describe(Face.default.eyes) == "oo")
        #expect(Bytes.describe(Face.default.tongue) == "  ")
    }

    @Test(arguments: [
        (FaceMode.borg, "=="), (.dead, "xx"), (.greedy, "$$"), (.paranoid, "@@"),
        (.stoned, "**"), (.tired, "--"), (.wired, "OO"), (.young, ".."),
    ])
    func allModesMatchCowsay(mode: FaceMode, eyes: String) {
        #expect(Bytes.describe(Face.construct(modes: [mode]).eyes) == eyes)
    }

    @Test func deadAndStonedAlsoSetTheTongue() {
        #expect(Bytes.describe(Face.construct(modes: [.dead]).tongue) == "U ")
        #expect(Bytes.describe(Face.construct(modes: [.stoned]).tongue) == "U ")
    }

    /// `construct_face` is a run of `if`s, not `elsif`, run in this order — so the last
    /// flag wins for the eyes while dead's tongue survives.
    @Test func laterModeWinsForEyesButTongueSticks() {
        let face = Face.construct(modes: [.dead, .young])
        #expect(Bytes.describe(face.eyes) == "..")
        #expect(Bytes.describe(face.tongue) == "U ")
    }

    /// `-e` is applied before `construct_face`, so any face flag overrides it.
    @Test func faceModeOverridesCustomEyes() {
        #expect(Bytes.describe(Face.construct(customEyes: Bytes.from("AB"),
                                              modes: [.borg]).eyes) == "==")
    }

    @Test func customEyesTruncatedToTwoBytes() {
        #expect(Bytes.describe(Face.construct(customEyes: Bytes.from("ABCDE")).eyes) == "AB")
        #expect(Bytes.describe(Face.construct(customTongue: Bytes.from("XYZ")).tongue) == "XY")
    }
}

// MARK: - Cowfile parsing

@Suite("Cowfile parsing")
struct CowfileParserTests {
    private func parse(_ source: String, name: String = "test") throws -> Cowfile {
        try CowfileParser.parse(name: name, contents: Bytes.from(source))
    }

    @Test func parsesBareHeredoc() throws {
        let cow = try parse("""
        ##
        ## A comment
        ##
        $the_cow = <<EOC;
        body
        EOC

        """)
        #expect(cow.header.map(Bytes.describe) == ["##", "## A comment", "##"])
        #expect(Bytes.describe(cow.template) == "body\n")
        #expect(cow.interpolating)
    }

    @Test func parsesQuotedTerminators() throws {
        #expect(try parse("$the_cow = <<\"EOC\";\nx\nEOC\n").interpolating)
        #expect(try !parse("$the_cow = <<'EOC';\nx\nEOC\n").interpolating)
        #expect(Bytes.describe(try parse("$the_cow = <<MOO;\nx\nMOO\n").template) == "x\n")
    }

    /// `sheep.cow` ships without one, which Perl accepts for a file's last statement.
    @Test func trailingSemicolonIsOptional() throws {
        #expect(Bytes.describe(try parse("$the_cow = <<EOC\nx\nEOC\n").template) == "x\n")
    }

    /// The rejection rule must be "everything outside the heredoc is inert", not a
    /// keyword search. All four cowfiles that cowsay 3.8.4 ships with real Perl would
    /// slip past an `if`/`for`/`sub` heuristic: two are plain assignments, and two use a
    /// trailing statement modifier so the keyword is not at statement position.
    @Test(arguments: [
        "$extra = chop($eyes);",              // three-eyes.cow
        "$other_eye = chop($eyes);",          // udder.cow
        "$eyes = \"..\" unless ($eyes);",     // small.cow
        "$eyes = '  ' unless ($eyes ne 'oo');", // sus.cow
    ])
    func rejectsCowfilesCarryingRealPerl(perl: String) {
        #expect(throws: CowfileParseError.unsupportedPerl(line: perl)) {
            try parse("\(perl)\n$the_cow = <<EOC;\nx\nEOC\n")
        }
    }

    @Test func rejectsMissingHeredoc() {
        #expect(throws: CowfileParseError.noHeredoc) { try parse("## just a comment\n") }
    }

    @Test func rejectsUnterminatedHeredoc() {
        #expect(throws: CowfileParseError.unterminatedHeredoc(terminator: "EOC")) {
            try parse("$the_cow = <<EOC;\nbody\n")
        }
    }

    @Test func rejectsTruecolorCows() {
        #expect(throws: CowfileParseError.truecolor) {
            try CowfileParser.parse(name: "truecolor/rainbow",
                                    contents: Bytes.from("$the_cow = <<EOC;\nx\nEOC\n"))
        }
    }
}

// MARK: - Cowfile rendering

@Suite("Cowfile rendering")
struct CowfileRenderTests {
    private func render(
        _ template: String,
        thoughts: UInt8 = UInt8(ascii: "\\"),
        face: Face = .default,
        interpolating: Bool = true
    ) -> String {
        let cow = Cowfile(name: "t", header: [], template: Bytes.from(template),
                          interpolating: interpolating)
        return Bytes.describe(CowfileParser.render(cow, thoughts: thoughts, face: face))
    }

    @Test func substitutesTheThreeKnownVariables() {
        #expect(render("$thoughts($eyes)$tongue|") == "\\(oo)  |")
        #expect(render("${thoughts}(${eyes})${tongue}|") == "\\(oo)  |")
    }

    @Test func unescapesPerlDoubleQuoteEscapes() {
        #expect(render(#"\\ \$ \@ \" \- \|"#) == #"\ $ @ " - |"#)
    }

    /// Why the pass has to be single and left-to-right: `-g` sets the eyes to `$$` and
    /// `-p` to `@@`. A second pass over the output would re-read those as metacharacters
    /// and mangle the cow.
    @Test func substitutedValuesAreNeverRescanned() {
        #expect(render("($eyes)", face: Face.construct(modes: [.greedy])) == "($$)")
        #expect(render("($eyes)", face: Face.construct(modes: [.paranoid])) == "(@@)")
        // An eye string that itself looks like an escape must survive intact too.
        #expect(render("($eyes)", face: Face.construct(customEyes: Bytes.from(#"\n"#)))
                == #"(\n)"#)
    }

    @Test func unknownVariablesAreLeftLiteral() {
        #expect(render("$other_eye and $extra") == "$other_eye and $extra")
    }

    @Test func singleQuotedHeredocDoesNotInterpolate() {
        #expect(render("$eyes and \\n", interpolating: false) == "$eyes and \\n")
    }

    /// `$eyes` must not swallow a longer identifier that merely starts with it.
    @Test func variableNamesMatchWholeIdentifiers() {
        #expect(render("$eyesocket") == "$eyesocket")
    }
}
