import Foundation

/// A chain's notes: the running log you and its agents write so a request made while
/// the swarm works is not lost, plus a headline summary. The file is the sidecar's
/// (`apps/oracle-mcp/src/chain-notes.ts`): one JSON object per line in
/// `~/.juancode/chain-notes/<chain id>.jsonl`. The app reads it and appends your notes.
public struct ChainNote: Codable, Sendable, Equatable, Identifiable {
    public var at: Int
    /// "you", or the juancode session id that wrote it.
    public var author: String
    public var authorName: String?
    /// "note" or "summary".
    public var kind: String
    public var text: String

    public var id: String { "\(at)|\(author)|\(text.hashValue)" }
    public var isSummary: Bool { kind == "summary" }
    public var byYou: Bool { author == "you" }

    public init(at: Int, author: String, authorName: String? = nil, kind: String, text: String) {
        self.at = at; self.author = author; self.authorName = authorName
        self.kind = kind; self.text = text
    }
}

public enum ChainNotes {
    public static let maxChars = 8000

    public static func directory() -> URL {
        if let dir = ProcessInfo.processInfo.environment["JUANCODE_CHAIN_NOTES_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".juancode/chain-notes")
    }

    /// Nil for an id that could name a path outside the directory.
    public static func file(chainId: String, in dir: URL = directory()) -> URL? {
        let ok = !chainId.isEmpty && !chainId.hasPrefix(".")
            && chainId.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        return ok ? dir.appendingPathComponent("\(chainId).jsonl") : nil
    }

    /// Oldest first; a torn line is skipped.
    public static func read(chainId: String, in dir: URL = directory()) -> [ChainNote] {
        guard let url = file(chainId: chainId, in: dir),
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(ChainNote.self, from: Data($0))
        }
    }

    /// Append one note as a single O_APPEND write, so it cannot interleave with the
    /// sidecar's. Returns the note written.
    @discardableResult
    public static func append(chainId: String, text: String, summary: Bool = false,
                              in dir: URL = directory()) throws -> ChainNote {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxChars,
              let url = file(chainId: chainId, in: dir) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let note = ChainNote(at: Int(Date().timeIntervalSince1970 * 1000), author: "you",
                             kind: summary ? "summary" : "note", text: trimmed)
        var line = try JSONEncoder().encode(note)
        line.append(UInt8(ascii: "\n"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else { throw CocoaError(.fileWriteUnknown) }
        return note
    }
}
