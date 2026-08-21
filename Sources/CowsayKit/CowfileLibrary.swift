import Foundation

/// A directory of cowfiles, loaded once and held in memory.
///
/// Loading never throws. A cowfile this parser cannot handle is recorded in `failures` and
/// skipped. The screensaver bundles only static cowfiles, so its bundled set has no parse
/// failures; callers such as the CLI can still report unsupported external cowfiles.
public struct CowfileLibrary: Sendable {
    public struct Failure: Sendable, Equatable {
        public let name: String
        public let path: String
        public let reason: String
    }

    public private(set) var cows: [String: Cowfile]
    public private(set) var failures: [Failure]

    public var names: [String] { cows.keys.sorted() }
    public var isEmpty: Bool { cows.isEmpty }

    public init(cows: [String: Cowfile] = [:], failures: [Failure] = []) {
        self.cows = cows
        self.failures = failures
    }

    public func cow(named name: String) -> Cowfile? { cows[name] }

    /// Scan directories for `*.cow`, in order. Earlier directories win on name collision,
    /// matching cowsay's cowpath precedence.
    public static func load(directories: [URL]) -> CowfileLibrary {
        var cows: [String: Cowfile] = [:]
        var failures: [Failure] = []
        let fm = FileManager.default

        for directory in ResourceLocations.standardizedDirectories(directories) {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard let walker = fm.enumerator(atPath: directory.path) else { continue }

            for case let relative as String in walker {
                guard relative.hasSuffix(".cow") else { continue }
                let name = String(relative.dropLast(4))
                // Skip the truecolor cowdir: those files are full of ANSI escape
                // sequences and render as garbage in a text layer.
                if name.hasPrefix("truecolor/") { continue }
                if cows[name] != nil { continue }

                let path = directory.appendingPathComponent(relative)
                guard let data = fm.contents(atPath: path.path) else {
                    failures.append(.init(name: name, path: path.path, reason: "unreadable"))
                    continue
                }
                do {
                    cows[name] = try CowfileParser.parse(name: name, contents: ByteString(data))
                } catch let error as CowfileParseError {
                    failures.append(.init(name: name, path: path.path, reason: error.description))
                } catch {
                    failures.append(.init(name: name, path: path.path, reason: "\(error)"))
                }
            }
        }
        return CowfileLibrary(cows: cows, failures: failures)
    }
}
