import Foundation
@testable import JuancodeServer

/// One connection under test: the live object, plus a drain of everything it put
/// on the wire. Built through `openConnection` so the handshake and the fan-out
/// start in the same order the real socket does.
///
/// Shared by every suite that drives `WebSocketConnection.handle` directly, which
/// is the only way to exercise a client frame without a real socket.
final class ConnectionTap {
    let conn: WebSocketConnection
    private let stream: AsyncStream<ServerMessage>
    private let cont: AsyncStream<ServerMessage>.Continuation

    init(state: AppState) {
        let (stream, cont) = AsyncStream<ServerMessage>.makeStream()
        self.stream = stream
        self.cont = cont
        conn = JuancodeServer.openConnection(state: state, gate: WSSendGate(cont: cont))
    }

    /// Close the connection and collect every frame it sent, as JSON objects.
    /// Closing is part of the contract under test: it releases the grids this
    /// client owned, which is the only way a release edge ever happens.
    func drain() async -> [[String: Any]] {
        conn.stopOutput()
        conn.close()
        cont.finish()
        var out: [[String: Any]] = []
        for await msg in stream {
            if let obj = try? JSONSerialization.jsonObject(
                with: Data(msg.jsonString().utf8)) as? [String: Any] {
                out.append(obj)
            }
        }
        return out
    }
}

/// The drained frames of one type, in the order they were sent.
func frames(_ all: [[String: Any]], ofType type: String) -> [[String: Any]] {
    all.filter { ($0["type"] as? String) == type }
}
