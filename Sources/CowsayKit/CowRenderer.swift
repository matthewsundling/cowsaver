import Foundation

/// How cowsay turns its input into the `@message` array before anything else happens.
public enum Message {
    /// `chomp(@message = <STDIN>)`.
    ///
    /// Reading lines and chomping each is not the same as splitting on newline: a single
    /// trailing newline terminates the last line rather than starting an empty one, but a
    /// *second* trailing newline is a real empty line and must survive.
    public static func linesFromStdin(_ data: ByteString) -> [ByteString] {
        guard !data.isEmpty else { return [] }
        var lines = Bytes.split(data, on: Bytes.lf, dropTrailingEmpty: false)
        if data.last == Bytes.lf, lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// `@message = join(' ', @ARGV)` — note this is a single-element array, so a message
    /// given as arguments never contains a newline.
    public static func linesFromArguments(_ arguments: [String]) -> [ByteString] {
        guard !arguments.isEmpty else { return [] }
        return [Bytes.from(arguments.joined(separator: " "))]
    }
}

public struct CowsayRequest {
    public var message: [ByteString]
    public var cowfile: Cowfile
    public var mode: BalloonMode
    public var face: Face
    public var wrapColumns: Int
    /// `-n`: expand tabs and do not wrap, matching cowsay's implementation.
    public var noWrap: Bool

    public init(
        message: [ByteString],
        cowfile: Cowfile,
        mode: BalloonMode = .say,
        face: Face = .default,
        wrapColumns: Int = 40,
        noWrap: Bool = false
    ) {
        self.message = message
        self.cowfile = cowfile
        self.mode = mode
        self.face = face
        self.wrapColumns = wrapColumns
        self.noWrap = noWrap
    }
}

public enum CowRenderer {
    /// The whole pipeline: wrap, build the balloon, render the cow, concatenate.
    ///
    /// Rendering operates only on an already-parsed cowfile. File loading and cowfile
    /// parsing occur before this point, so the per-rotation path has a simple byte result.
    public static func render(_ request: CowsayRequest) -> ByteString {
        let wrapped = request.noWrap
            ? WordWrap.expandTabs(request.message)
            : WordWrap.fill(request.message, columns: request.wrapColumns)

        let balloon = BalloonBuilder.build(wrapped, mode: request.mode)
        let cow = CowfileParser.render(
            request.cowfile,
            thoughts: balloon.thoughts,
            face: request.face
        )

        var out = ByteString()
        out.reserveCapacity(cow.count + 256)
        for line in balloon.lines {
            out.append(contentsOf: line)
            out.append(Bytes.lf)
        }
        out.append(contentsOf: cow)
        return out
    }

    /// Convenience for callers holding a `String` — the screensaver and the tests both do.
    public static func render(
        message: String,
        cowfile: Cowfile,
        mode: BalloonMode = .say,
        face: Face = .default,
        wrapColumns: Int = 40
    ) -> ByteString {
        render(CowsayRequest(
            message: Message.linesFromStdin(Bytes.from(message)),
            cowfile: cowfile,
            mode: mode,
            face: face,
            wrapColumns: wrapColumns
        ))
    }
}
