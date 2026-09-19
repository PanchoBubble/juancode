import Foundation
import JuancodeCore
import JuancodeServer

/// `RustCoreClient`'s half of the working-tree surface (juancode-52e8.14.5).
///
/// Split across two transports, on purpose, and the split is the ticket's:
///
/// * **Reads go over HTTP**, straight at the daemon's own `127.0.0.1` listener. They
///   are questions with no ordering to keep against anything, they are already HTTP
///   for every remote client, and putting a dozen of them on the wire would have been
///   a dozen correlated frames and a dozen conformance assertions for no property the
///   socket gives them. The path-addressed family (`/api/git/…?cwd=`) exists because
///   the desktop asks about folders that are not any session's cwd — an orphaned
///   worktree whose session was deleted is exactly what the at-risk badge is for.
/// * **Writes go over the wire**, so a commit is ordered against the session's other
///   traffic and a refusal comes back naming itself: "Nothing to commit.", or the
///   hook's own words, rather than a status code somebody has to map back into a
///   sentence.
///
/// Every member here is gated on the `changes` capability before it sends anything.
/// A core that does not advertise it gets the extension's default — a thrown
/// `CoreCapabilityError` — and the panel greys itself out with that reason.
public extension RustCoreClient {

    // MARK: - Reads (HTTP)

    func diff(cwd: String) async throws -> DiffResult {
        try await gitGet("/api/git/diff", [("cwd", cwd)], as: DiffResult.self)
    }

    func baseDiff(cwd: String, base: String?) async throws -> BaseDiffResult {
        // The key is present with an empty value when no base is named: that is what
        // says "against this branch's own inferred base" rather than "against HEAD",
        // which is what its absence means.
        try await gitGet("/api/git/diff", [("cwd", cwd), ("base", base ?? "")],
                         as: BaseDiffResult.self)
    }

    func commitDiff(cwd: String, sha: String) async throws -> DiffResult {
        try await gitGet("/api/git/diff", [("cwd", cwd), ("commit", sha)], as: DiffResult.self)
    }

    func gitState(cwd: String) async throws -> GitState {
        try await gitGet("/api/git/state", [("cwd", cwd)], as: GitState.self)
    }

    func recentCommits(cwd: String, limit: Int) async throws -> [RecentCommit] {
        try await gitGet("/api/git/commits", [("cwd", cwd), ("limit", String(limit))],
                         as: [RecentCommit].self)
    }

    func worktrees(cwd: String) async throws -> [Worktree] {
        try await gitGet("/api/git/worktrees", [("cwd", cwd)], as: [Worktree].self)
    }

    /// Remove a linked worktree. The one WRITE that goes over HTTP rather than the
    /// socket, and for the same reason the path-addressed reads do: the caller is the
    /// worktree rail reaping a tree whose session is already gone, so there is no
    /// session id to address it by and no session traffic to order it against.
    func removeWorktree(path: String) async throws {
        try await gitDelete("/api/git/worktree", [("cwd", path)])
    }

    func worktreeStatus(cwd: String) async throws -> [WorktreeStatusEntry] {
        try await gitGet("/api/git/status", [("cwd", cwd)], as: [StatusEntryWire].self)
            .map(\.entry)
    }

    func trackedFiles(cwd: String, limit: Int) async throws -> [String] {
        try await gitGet("/api/git/files", [("cwd", cwd), ("limit", String(limit))],
                         as: [String].self)
    }

    func changeStat(cwd: String) async throws -> ChangeStat {
        try await gitGet("/api/git/changes", [("cwd", cwd)], as: ChangeStatWire.self).stat
    }

    func readFile(cwd: String, path: String) async throws -> String {
        try await gitGet("/api/git/file", [("cwd", cwd), ("path", path)],
                         as: FileBodyWire.self).content
    }

    func probeAtRisk(path: String) async throws -> AtRiskProbe? {
        try await gitGet("/api/git/at-risk", [("cwd", path)], as: AtRiskProbe?.self)
    }

    func agentWorktree(cwd: String, childPid: Int32) async throws -> String? {
        try await gitGet("/api/git/agent-worktree",
                         [("cwd", cwd), ("pid", String(childPid))],
                         as: AgentWorktreeWire.self).path
    }

    // MARK: - Writes (wire)

    func commitAll(sessionId: String, cwd: String?, message: String) async throws -> CommitResult {
        try await changesWrite(["type": "sessionCommit", "sessionId": sessionId,
                                "message": message], cwd: cwd, as: CommitResult.self)
    }

    func push(sessionId: String, cwd: String?) async throws -> PushResult {
        try await changesWrite(["type": "sessionPush", "sessionId": sessionId],
                               cwd: cwd, as: PushResult.self)
    }

    func revert(sessionId: String, cwd: String?, path: String,
                hunkIndex: Int?) async throws -> RevertResult {
        var frame: [String: Any] = ["type": "sessionRevert", "sessionId": sessionId,
                                    "path": path]
        if let hunkIndex { frame["hunkIndex"] = hunkIndex }
        return try await changesWrite(frame, cwd: cwd, as: RevertResult.self)
    }

    func draftCommitMessage(sessionId: String, cwd: String?) async throws -> String {
        try await changesWrite(["type": "sessionCommitMessage", "sessionId": sessionId],
                               cwd: cwd, timeout: Self.draftTimeout,
                               as: CommitMessageResult.self).message
    }

    // MARK: - Transport

    /// How long a git read is given. Generous because a cold `git diff` over a large
    /// change set on this machine pays a fork per file, and a fork here is 257ms
    /// before the child runs an instruction.
    internal static var readTimeout: TimeInterval { 30 }

    /// How long a git WRITE is given. A commit is milliseconds of git behind one fork;
    /// a push is a network round trip to a forge.
    internal static var writeTimeout: TimeInterval { 60 }

    /// How long a drafted commit message is given: it is a real `claude -p` run, and
    /// the daemon's own budget for it is two minutes.
    internal static var draftTimeout: TimeInterval { 130 }

    /// One read, decoded. A non-2xx carries the daemon's own `error` sentence, which
    /// is the one worth showing.
    private func gitGet<T: Decodable>(_ path: String, _ query: [(String, String)],
                                      as type: T.Type) async throws -> T {
        try requireChanges()
        guard var comps = URLComponents(string: baseURL) else {
            throw ChangesError("not a usable core URL: \(baseURL)")
        }
        comps.path = path
        comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = comps.url else {
            throw ChangesError("not a usable core URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.readTimeout
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ChangesError("the rust core did not answer \(path): \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            throw ChangesError(Self.errorSentence(data)
                ?? "the rust core answered \(status) for \(path)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ChangesError("could not read the core's answer to \(path): \(error)")
        }
    }

    /// One delete, with nothing to decode. A 204 is the whole answer; anything else
    /// carries the daemon's own sentence, which is the one worth showing.
    private func gitDelete(_ path: String, _ query: [(String, String)]) async throws {
        try requireChanges()
        guard var comps = URLComponents(string: baseURL) else {
            throw ChangesError("not a usable core URL: \(baseURL)")
        }
        comps.path = path
        comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = comps.url else {
            throw ChangesError("not a usable core URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        // A worktree removal is a `git worktree remove` behind a fork, not a network
        // round trip, so the read budget covers it with room to spare.
        request.timeoutInterval = Self.readTimeout
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ChangesError("the rust core did not answer DELETE \(path): "
                               + error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            throw ChangesError(Self.errorSentence(data)
                ?? "the rust core answered \(status) for DELETE \(path)")
        }
    }

    /// The `error` field of a daemon failure body, when there is one.
    private static func errorSentence(_ data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = obj["error"] as? String, !message.isEmpty else { return nil }
        return message
    }

    /// One write, correlated, decoded from the `result` of its `changesResult`.
    ///
    /// Silence is a failure, never a success. A destructive frame that nobody
    /// confirmed has not happened, and a Discard button that clears its row on a
    /// timeout is telling somebody their file is gone when it may not be.
    private func changesWrite<T: Decodable>(_ frame: [String: Any], cwd: String?,
                                            timeout: TimeInterval? = nil,
                                            as type: T.Type) async throws -> T {
        try requireChanges()
        var body = frame
        if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        let waiter = ChangesWaiter()
        let requestId = lock.withLock { () -> String in
            let id = "changes-\(nextChangesId)"
            nextChangesId += 1
            changesWaiters[id] = waiter
            return id
        }
        body["requestId"] = requestId
        connection.send(body)
        defer { lock.withLock { changesWaiters[requestId] = nil } }

        let op = (frame["type"] as? String) ?? "write"
        guard let reply = await waiter.wait(timeout: timeout ?? Self.writeTimeout) else {
            throw ChangesError("the rust core did not answer \(op) within "
                               + "\(Int(timeout ?? Self.writeTimeout))s, so it has not happened")
        }
        if let message = reply.error, !message.isEmpty {
            throw ChangesError(message)
        }
        guard let data = reply.result else {
            throw ChangesError("the rust core answered \(op) with nothing to read")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ChangesError("could not read the core's answer to \(op): \(error)")
        }
    }

    private func requireChanges() throws {
        guard supports(.changes) else {
            throw CoreCapabilityError(.changes, backend: backendName)
        }
    }
}

/// A working-tree failure, already worded for a person: git's own first line, the
/// daemon's refusal, or this client's reason for having no answer at all.
public struct ChangesError: LocalizedError {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

// MARK: - decode shims

/// `WorktreeStatusEntry` holds `Character`s and is not `Codable`; the wire carries the
/// two status codes as one-character strings. Shimmed here rather than making the model
/// `Codable`, so the model keeps the type that makes `untracked` a comparison.
private struct StatusEntryWire: Decodable {
    let path: String
    let origPath: String?
    let index: String
    let workTree: String

    var entry: WorktreeStatusEntry {
        WorktreeStatusEntry(path: path, origPath: origPath,
                            index: index.first ?? " ", workTree: workTree.first ?? " ")
    }
}

private struct ChangeStatWire: Decodable {
    let files: Int
    let additions: Int
    let deletions: Int
    let signature: String

    var stat: ChangeStat {
        ChangeStat(files: files, additions: additions, deletions: deletions,
                   signature: signature)
    }
}

private struct FileBodyWire: Decodable {
    let path: String
    let content: String
}

private struct AgentWorktreeWire: Decodable {
    let path: String?
}

/// A `changesResult`, reduced to the two things a caller does anything with.
///
/// `result` is kept as encoded bytes rather than as the frame's `[String: Any]`
/// because it crosses a continuation: a dictionary of `Any` is not `Sendable`, and
/// re-encoding it once on the socket's thread is cheaper than the compiler being
/// right about the race.
struct ChangesReply: Sendable {
    var error: String?
    var result: Data?
}

/// One git write waiting on the daemon.
///
/// A continuation rather than the semaphore `SearchWaiter` uses, because every caller
/// here is async all the way down — a commit is a button press on the main actor and
/// there is nothing to block. One-shot: the reply and the expiry race, and the loser
/// must not resume a continuation the winner already used.
final class ChangesWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ChangesReply?, Never>?
    private var settled = false
    private var reply: ChangesReply?

    /// The answer, or nil when the budget ran out.
    func wait(timeout: TimeInterval) async -> ChangesReply? {
        let timer = Task { [weak self] in
            await Nap.duration(.milliseconds(Int(timeout * 1000)))
            self?.settle(nil)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { (cont: CheckedContinuation<ChangesReply?, Never>) in
            let ready: Bool = lock.withLock {
                if settled { return true }
                continuation = cont
                return false
            }
            if ready { cont.resume(returning: lock.withLock { reply }) }
        }
    }

    func deliver(_ body: [String: Any]) {
        settle(ChangesReply(
            error: body["error"] as? String,
            result: body["result"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }))
    }

    /// Fail the wait now with a reason, rather than letting it sit out its budget for
    /// an answer whose transport is already gone.
    func fail(_ reason: String) {
        settle(ChangesReply(error: reason, result: nil))
    }

    private func settle(_ value: ChangesReply?) {
        let waiting: CheckedContinuation<ChangesReply?, Never>? = lock.withLock {
            guard !settled else { return nil }
            settled = true
            reply = value
            let taken = continuation
            continuation = nil
            return taken
        }
        waiting?.resume(returning: value)
    }
}

// MARK: - the relay's writes

public extension RustCoreClient {
    /// Run one of the relay's working-tree writes and encode what the daemon answered.
    ///
    /// The phone reaches the desktop's `:4280`, not the daemon, so its POST lands here
    /// and becomes the same frame the desktop's own button sends. Encoded back to JSON
    /// rather than handed over as a value, because the relay's job is to be
    /// transparent: the client gets the core's shape, not this hop's opinion of it.
    func relayGitWrite(_ request: CoreProxyServer.GitWrite) async -> CoreProxyServer.GitWriteOutcome {
        do {
            let payload: any Encodable
            switch request.kind {
            case .commit:
                payload = try await commitAll(sessionId: request.sessionId, cwd: request.cwd,
                                              message: request.message ?? "")
            case .push:
                payload = try await push(sessionId: request.sessionId, cwd: request.cwd)
            case .revert:
                payload = try await revert(sessionId: request.sessionId, cwd: request.cwd,
                                           path: request.path ?? "", hunkIndex: request.hunkIndex)
            case .commitMessage:
                payload = CommitMessageResult(
                    message: try await draftCommitMessage(sessionId: request.sessionId,
                                                          cwd: request.cwd))
            }
            return .ok(try JSONEncoder().encode(payload))
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription
                           ?? error.localizedDescription)
        }
    }
}
