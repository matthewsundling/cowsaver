import Foundation

/// Where Cowsaver looks for its config file and personal fortune content.
///
/// The front ends have different filesystem views. The `.saver` runs inside
/// `legacyScreenSaver.appex`, where `NSHomeDirectory()` is the sandbox container; the
/// standalone app sees the user's home directory.
///
/// Foundation resolves Application Support in each context. The explicit container path
/// also lets the standalone app find content imported for the screensaver. Existing paths
/// are used in order.
public enum ResourceLocations {
    public static let containerPath =
        "Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data"

    /// Directories that may hold a user's own config and content, most specific first.
    public static func supportDirectories() -> [URL] {
        var directories: [URL] = []

        if let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first {
            directories.append(support.appendingPathComponent("Cowsaver"))
        }

        // Add the screensaver container explicitly. Inside the sandbox this duplicates the
        // Application Support result; outside it, it locates imported screensaver content.
        let home = URL(fileURLWithPath: NSHomeDirectory())
        directories.append(
            home.appendingPathComponent(containerPath)
                .appendingPathComponent("Library/Application Support/Cowsaver")
        )

        var seen = Set<String>()
        return directories.filter { seen.insert($0.standardizedFileURL.path).inserted }
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
        var directories: [URL] = []
        if let resources = bundle?.resourceURL {
            directories.append(resources.appendingPathComponent("cows"))
        }
        directories += developmentFallbacks(subdirectory: "cows")
        return directories
    }

    /// Fortune directories: a user's collection first, then the bundled curated set. The
    /// preserved upstream import is not a runtime search path.
    public static func fortuneDirectories(bundle: Bundle?) -> [URL] {
        var directories = supportDirectories().map { $0.appendingPathComponent("fortune-user") }
        if let resources = bundle?.resourceURL {
            directories.append(resources.appendingPathComponent("fortune-curated"))
        }
        directories += developmentFallbacks(subdirectory: "fortune-curated")
        return directories
    }

    /// Lets the standalone app run from a checkout when no bundle resources are available.
    private static func developmentFallbacks(subdirectory: String) -> [URL] {
        [URL(fileURLWithPath: "Resources").appendingPathComponent(subdirectory)]
    }
}
