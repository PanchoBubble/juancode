import Foundation

/// The oracle sidecar, reached at the second paired URL with the same Bearer token.
/// Only the chat turn: `POST /api/chat/stream`, read as Server-Sent Events.
struct SidecarClient: Sendable {
    let base: URL
    let token: String

    enum Event: Sendable {
        case delta(String)
        /// Final frame: the thread id to resume next turn.
        case done(sessionId: String?, isError: Bool)
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    /// Whisper on the Mac: an m4a recording in, its transcript out (`POST /api/transcribe`).
    func transcribe(m4a: Data) async throws -> String {
        var req = URLRequest(url: base.appending(path: "api/transcribe"))
        req.httpMethod = "POST"
        req.timeoutInterval = 240
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: req, from: m4a)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure(errorDescription: status == 401
                ? "The sidecar rejected the pairing token. Scan the QR again."
                : "Transcription failed (\(status)).")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String ?? ""
    }

    /// Raw bytes to the Mac (`POST /api/uploads?name=`); returns the saved file's path there,
    /// which goes into the message so the agent on the Mac reads it.
    func upload(_ data: Data, name: String) async throws -> String {
        var comps = URLComponents(url: base.appending(path: "api/uploads"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "name", value: name)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (body, resp) = try await URLSession.shared.upload(for: req, from: data)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let path = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["path"] as? String
        else {
            throw Failure(errorDescription: status == 401
                ? "The sidecar rejected the pairing token. Scan the QR again."
                : "Upload failed (\(status)).")
        }
        return path
    }

    func chat(text: String, sessionId: String?, provider: String) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var req = URLRequest(url: base.appending(path: "api/chat/stream"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 600
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    // `provider` is read by sidecars that offer the claude/codex choice; older ones ignore it.
                    var body: [String: Any] = ["text": text, "provider": provider]
                    if let sessionId { body["sessionId"] = sessionId }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                        throw Failure(errorDescription: http.statusCode == 401
                            ? "The sidecar rejected the pairing token. Scan the QR again."
                            : "Sidecar answered \(http.statusCode).")
                    }
                    // `lines` drops the blank separator, so a frame is its `event:` then `data:` line.
                    var event = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:"),
                                  let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any] {
                            switch event {
                            case "delta": if let t = obj["text"] as? String { cont.yield(.delta(t)) }
                            case "done": cont.yield(.done(sessionId: obj["sessionId"] as? String,
                                                          isError: obj["isError"] as? Bool ?? false))
                            case "error": throw Failure(errorDescription: obj["message"] as? String ?? "stream interrupted")
                            default: break
                            }
                        }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
