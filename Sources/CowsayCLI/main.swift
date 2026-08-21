import CowsayKit
import Foundation

// cowsaver-cli — the same core the screensaver uses, printing to stdout.
//
// It exists so the golden tests (and humans) can diff us against real cowsay directly.
// That makes byte-exact output the whole point: everything below writes `Data` to a file
// handle rather than using `print`, which would append its own newline and re-encode.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("cowsaver-cli: \(message)\n".utf8))
    exit(1)
}

func emit(_ bytes: ByteString) {
    FileHandle.standardOutput.write(Data(bytes))
}

// MARK: - Config validation

func printValidation(_ result: Configuration.LoadResult) {
    if result.warnings.isEmpty {
        emit(Bytes.from("ok\n"))
    } else {
        for warning in result.warnings { emit(Bytes.from("\(warning)\n")) }
    }
}

/// `--print-default-config`: the shipped defaults as a config file, for someone who wants a
/// starting point rather than a blank editor.
///
/// Written with the same JSON formatting options the settings window uses to write
/// `config.json`, so the output is the file the settings window would have written. An unset
/// `theme` is omitted, exactly as it is on disk, which leaves the raw `foreground` and
/// `background` values active.
func printDefaultConfig() -> Never {
    guard let data = try? JSONSerialization.data(withJSONObject: Configuration().jsonObject,
                                                 options: [.prettyPrinted, .sortedKeys]) else {
        fail("could not serialize the default configuration")
    }
    emit(Bytes.from(String(decoding: data, as: UTF8.self) + "\n"))
    exit(0)
}

/// `--validate-config`: the same loader the saver uses, so a warning here is a warning
/// there. A missing or unreadable file is only an error when the caller named it
/// explicitly; searching the default locations and finding nothing is normal.
func validateConfig(path: String?) -> Never {
    if let path {
        guard let data = FileManager.default.contents(atPath: path) else {
            fail("no config file at \(path)")
        }
        printValidation(Configuration.load(data: data))
        exit(0)
    }

    emit(Bytes.from("config search order:\n"))
    var found: URL?
    for directory in ResourceLocations.supportDirectories() {
        let candidate = directory.appendingPathComponent("config.json")
        let exists = FileManager.default.fileExists(atPath: candidate.path)
        if exists, found == nil { found = candidate }
        emit(Bytes.from("  \(exists ? "*" : " ") \(candidate.path)\n"))
    }
    guard let found, let data = FileManager.default.contents(atPath: found.path) else {
        emit(Bytes.from("no config file found; the saver uses built-in defaults\n"))
        exit(0)
    }
    printValidation(Configuration.load(data: data))
    exit(0)
}

// MARK: - Cow search path

func defaultCowDirectories() -> [URL] {
    var directories: [URL] = []
    if let env = ProcessInfo.processInfo.environment["COWSAVER_COWDIR"] {
        directories += env.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
    }
    directories.append(URL(fileURLWithPath: "Resources/cows"))
    // Also look beside the executable, so a built binary works from anywhere.
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    directories.append(executable.appendingPathComponent("Resources/cows"))
    return directories
}

// MARK: - Argument parsing

var cowName = "default"
var explicitPath: String?
var wrapColumns = 40
var noWrap = false
var customEyes: ByteString?
var customTongue: ByteString?
var modes: Set<FaceMode> = []
var listCows = false
var cowDirectories = defaultCowDirectories()

// cowthink is selected by program name in real cowsay ($0 =~ /think/i). Honour that, and
// also accept --think so one binary can serve both in the golden generator.
var mode: BalloonMode =
    URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent.lowercased().contains("think")
    ? .think : .say

var messageArguments: [String] = []
var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0

func nextValue(_ flag: String) -> String {
    index += 1
    guard index < arguments.count else { fail("option \(flag) requires a value") }
    return arguments[index]
}

while index < arguments.count {
    let argument = arguments[index]

    if argument == "--" {
        index += 1
        messageArguments += arguments[index...]
        break
    }
    // Prints the stable ID for a quote, so someone requesting removal of a misattributed
    // or copyrighted fortune can name it exactly. See Resources/fortune-curated/provenance.md.
    if argument == "--fortune-id" {
        let text = nextValue("--fortune-id")
        emit(Bytes.from(Fortune.identifier(for: text) + "\n"))
        exit(0)
    }
    if argument == "--think" { mode = .think; index += 1; continue }
    if argument == "--say" { mode = .say; index += 1; continue }
    if argument == "--cowdir" {
        cowDirectories = [URL(fileURLWithPath: nextValue("--cowdir"))]
        index += 1
        continue
    }
    if argument == "--help" || argument == "-h" {
        emit(Bytes.from("""
        cowsaver-cli — a byte-compatible reimplementation of cowsay 3.8.4

        Usage: cowsaver-cli [-bdgpstwy] [-f <cowfile>] [-e <eyes>] [-T <tongue>]
                            [-W <columns>] [-n] [--think] [--cowdir <dir>] [message]
               cowsaver-cli --validate-config [path]
               cowsaver-cli --print-default-config

        Reads the message from stdin when none is given as arguments.

        --validate-config [path] checks a config.json for warnings instead of rendering
        anything. With no path, it searches the same locations the screensaver does.

        --print-default-config writes the shipped defaults as a config.json to stdout.

        """))
        exit(0)
    }
    if argument == "--print-default-config" {
        printDefaultConfig()
    }
    if argument == "--validate-config" {
        var path: String?
        if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
            index += 1
            path = arguments[index]
        }
        validateConfig(path: path)
    }

    // Getopt::Std allows bundling, so -bdg is three flags.
    if argument.hasPrefix("-"), argument.count > 1, !argument.hasPrefix("--") {
        let characters = Array(argument.dropFirst())
        var position = 0
        while position < characters.count {
            let flag = characters[position]
            if let face = FaceMode.fromFlag(flag) {
                modes.insert(face)
                position += 1
                continue
            }
            switch flag {
            case "n":
                noWrap = true
                position += 1
            case "l":
                listCows = true
                position += 1
            case "f", "e", "T", "W":
                // Value flags take the rest of the token, or the next argument.
                let inline = String(characters[(position + 1)...])
                let value = inline.isEmpty ? nextValue("-\(flag)") : inline
                switch flag {
                case "f":
                    if value.hasSuffix(".cow") || value.contains("/") {
                        explicitPath = value
                    } else {
                        cowName = value
                    }
                case "e": customEyes = Bytes.from(value)
                case "T": customTongue = Bytes.from(value)
                case "W":
                    guard let columns = Int(value) else { fail("-W expects a number, got \(value)") }
                    wrapColumns = columns
                default: break
                }
                position = characters.count
            default:
                fail("unknown option -\(flag)")
            }
        }
        index += 1
        continue
    }

    messageArguments.append(argument)
    index += 1
}

// MARK: - Load the cow

let library = CowfileLibrary.load(directories: cowDirectories)

if listCows {
    if library.isEmpty {
        fail("no cowfiles found in \(cowDirectories.map(\.path).joined(separator: ", "))")
    }
    emit(Bytes.from(library.names.joined(separator: "\n") + "\n"))
    for failure in library.failures {
        FileHandle.standardError.write(Data("skipped \(failure.name): \(failure.reason)\n".utf8))
    }
    exit(0)
}

let cowfile: Cowfile
if let explicitPath {
    guard let data = FileManager.default.contents(atPath: explicitPath) else {
        fail("could not read cowfile \(explicitPath)")
    }
    let name = URL(fileURLWithPath: explicitPath).deletingPathExtension().lastPathComponent
    do {
        cowfile = try CowfileParser.parse(name: name, contents: ByteString(data))
    } catch {
        fail("\(explicitPath): \(error)")
    }
} else if let found = library.cow(named: cowName) {
    cowfile = found
} else if let failure = library.failures.first(where: { $0.name == cowName }) {
    fail("cannot use cowfile '\(cowName)': \(failure.reason)")
} else {
    fail("could not find cowfile for '\(cowName)' in \(cowDirectories.map(\.path).joined(separator: ", "))")
}

// MARK: - Render

// Real cowsay refuses -n with an argument message; it only works on stdin.
if noWrap, !messageArguments.isEmpty { fail("-n only works with input on stdin") }

let message: [ByteString] = messageArguments.isEmpty
    ? Message.linesFromStdin(ByteString(FileHandle.standardInput.readDataToEndOfFile()))
    : Message.linesFromArguments(messageArguments)

let request = CowsayRequest(
    message: message,
    cowfile: cowfile,
    mode: mode,
    face: Face.construct(customEyes: customEyes, customTongue: customTongue, modes: modes),
    wrapColumns: wrapColumns,
    noWrap: noWrap
)

emit(CowRenderer.render(request))
