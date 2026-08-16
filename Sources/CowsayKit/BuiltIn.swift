import Foundation

/// Minimal fallback content compiled into the binary.
///
/// The engine uses these values when bundled resources cannot be loaded. `defaultCowSource`
/// is a copy of `Resources/cows/default.cow`; the test suite keeps the two renderings aligned.
public enum BuiltIn {
    public static let defaultCowSource = #"""
    $the_cow = <<"EOC";
            $thoughts   ^__^
             $thoughts  ($eyes)\\_______
                (__)\\       )\\/\\
                 $tongue ||----w |
                    ||     ||
    EOC
    """#

    /// Parse the compiled source once; retain a minimal template if parsing fails.
    public static let defaultCow: Cowfile = {
        (try? CowfileParser.parse(name: "default", contents: Bytes.from(defaultCowSource)))
            ?? Cowfile(name: "default", header: [], template: Bytes.from("  $thoughts ($eyes)\n"),
                       interpolating: true)
    }()

    /// Fallback quotations from fortune-mod. Their licence text is included with the runtime
    /// corpus at `Resources/fortune-curated/license.txt`.
    public static let fortunes: [String] = [
        "The steady state of disks is full. -- Ken Thompson",
        "There is no such thing as fortune.  Try again.",
        "Weekends were made for programming. - Karl Lehenbauer",
        "Age and treachery will always overcome youth and skill.",
        "The important thing is not to stop questioning.",
        "Many people write memos to tell you they have nothing to say.",
        "There's an old proverb that says just about whatever you want it to.",
        "Intel CPUs are not defective, they just act that way. -- Henry Spencer",
    ]
}
