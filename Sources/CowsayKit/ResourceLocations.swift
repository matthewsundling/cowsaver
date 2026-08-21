import Foundation

/// Where Cowsaver looks for its config file and personal fortune content.
///
/// The front ends have different filesystem views. The `.saver` runs inside
/// `legacyScreenSaver.appex`, where `NSHomeDirectory()` is the sandbox container; the
/// standalone app sees the user's home directory.
///
/// The screensaver container is canonical: it is the one directory both front ends resolve
/// to the same files, so it comes first in every search and is where settings are written.
/// The real home's Application Support directory follows it, which keeps a config or
/// imported fortunes already living there in use.
public enum ResourceLocations {
    public static let containerPath =
        "Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data"

    /// The `config.json` both front ends read and write.
    public static func canonicalConfigurationURL() -> URL {
        containerSupportDirectory().appendingPathComponent("config.json")
    }

    /// Directories that may hold a user's own config and content, canonical location first.
    public static func supportDirectories() -> [URL] {
        var directories: [URL] = [containerSupportDirectory()]

        // Outside the sandbox this is the user's own Application Support directory; inside
        // it, it is the container directory again and dedupes away.
        if let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first {
            directories.append(support.appendingPathComponent("Cowsaver"))
        }

        var seen = Set<String>()
        return directories.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The container's Application Support directory, seen from either side of the sandbox.
    ///
    /// Inside `legacyScreenSaver.appex` the home directory is already the container's `Data`
    /// directory, so appending the container path again would nest a second copy of it that
    /// no process ever writes to.
    private static func containerSupportDirectory() -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        let data = home.path.hasSuffix("/" + containerPath)
            ? home
            : home.appendingPathComponent(containerPath)
        return data.appendingPathComponent("Library/Application Support/Cowsaver")
    }

    /// Return the first existing `config.json` in the search order.
    public static func configurationURL() -> URL? {
        for directory in supportDirectories() {
            let candidate = directory.appendingPathComponent("config.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Cowfile resources bundled with Cowsaver.
    public static func cowDirectories(bundle: Bundle?) -> [URL] {
        cowDirectories(bundleResourceURL: bundle?.resourceURL,
                       developmentResourceURL: developmentResourcesURL())
    }

    /// Fortune directories: a user's collection first, then the bundled curated set. The
    /// preserved upstream import is not a runtime search path.
    public static func fortuneDirectories(bundle: Bundle?) -> [URL] {
        fortuneDirectories(supportDirectories: supportDirectories(),
                           bundleResourceURL: bundle?.resourceURL,
                           developmentResourceURL: developmentResourcesURL())
    }

    /// Internal seams keep discovery testable without changing the front ends' bundle API.
    static func cowDirectories(bundleResourceURL: URL?, developmentResourceURL: URL) -> [URL] {
        bundledOrDevelopmentDirectories(subdirectory: "cows", bundleResourceURL: bundleResourceURL,
                                        developmentResourceURL: developmentResourceURL)
    }

    static func fortuneDirectories(supportDirectories: [URL], bundleResourceURL: URL?,
                                   developmentResourceURL: URL) -> [URL] {
        standardizedDirectories(
            supportDirectories.map { $0.appendingPathComponent("fortune-user") }
                + bundledOrDevelopmentDirectories(
                    subdirectory: "fortune-curated", bundleResourceURL: bundleResourceURL,
                    developmentResourceURL: developmentResourceURL
                )
        )
    }

    /// A bundle is authoritative only when the requested collection is actually present.
    /// This retains checkout loading for source-tree runs without loading the same collection
    /// again beside a packaged copy.
    private static func bundledOrDevelopmentDirectories(
        subdirectory: String,
        bundleResourceURL: URL?,
        developmentResourceURL: URL
    ) -> [URL] {
        if let bundleResourceURL {
            let bundled = bundleResourceURL.appendingPathComponent(subdirectory)
            if isDirectory(bundled) { return standardizedDirectories([bundled]) }
        }
        return standardizedDirectories([developmentResourceURL.appendingPathComponent(subdirectory)])
    }

    /// Lets the standalone app run from a checkout when no bundle resources are available.
    private static func developmentResourcesURL() -> URL {
        URL(fileURLWithPath: "Resources")
    }

    /// Preserve search precedence while treating equivalent spellings of one root as one input.
    static func standardizedDirectories(_ directories: [URL]) -> [URL] {
        var seen = Set<String>()
        return directories.map(\.standardizedFileURL).filter {
            seen.insert($0.path).inserted
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
