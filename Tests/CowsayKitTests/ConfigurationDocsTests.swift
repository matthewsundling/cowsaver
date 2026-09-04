import Foundation
import Testing
@testable import CowsayKit

/// Keeps the configuration documentation honest.
///
/// `docs/configuration.md` and `docs/config.example.json` describe the keys
/// `Configuration` understands. Nothing in the build forces them to stay in step, so these
/// tests do: adding a nonoptional field without putting it in the example, omitting any field
/// from the reference, or leaving a retired key in the example fails here rather than reaching
/// a reader who then configures something that no longer exists.
///
/// The documents are read from the source tree, the same way `GoldenTests` reads its
/// fixtures, so the files under review are the files under test.
@Suite("Configuration documentation")
struct ConfigurationDocsTests {
    static let exampleURL = GoldenTests.repositoryRoot
        .appendingPathComponent("docs/config.example.json")
    static let referenceURL = GoldenTests.repositoryRoot
        .appendingPathComponent("docs/configuration.md")

    private static func exampleObject() throws -> [String: Any] {
        let data = try Data(contentsOf: exampleURL)
        let parsed = try JSONSerialization.jsonObject(with: data)
        return try #require(parsed as? [String: Any], "the example is not a JSON object")
    }

    /// Optional custom face strings are omitted at their default nil value. Every other key
    /// appears, and the example cannot keep a key the loader has dropped.
    @Test func theExampleHoldsEveryNonoptionalKnownKey() throws {
        let keys = Set(try Self.exampleObject().keys)
        let required = Set(Configuration.knownKeys).subtracting(["eyes", "tongue"])
        let missing = required.subtracting(keys).sorted()
        let unknown = keys.subtracting(Configuration.knownKeys).sorted()
        #expect(keys == required,
                "missing from the example: \(missing); unknown to the loader: \(unknown)")
    }

    /// Every key needs prose, not just a line in the example file.
    @Test func theReferenceDocumentsEveryKnownKey() throws {
        let reference = try String(contentsOf: Self.referenceURL, encoding: .utf8)
        for key in Configuration.knownKeys {
            #expect(reference.contains(key), "\(key) is not documented in docs/configuration.md")
        }
    }
}
