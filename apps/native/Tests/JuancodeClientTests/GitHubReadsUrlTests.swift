import Foundation
import Testing
@testable import JuancodeClient

/// Records what `GitHubReads` puts on the wire. A PR with no checkout must be named by
/// its URL alone — a `cwd` the core cannot `cd` into would fail every call — while a
/// listed PR keeps naming its checkout and number.
@Suite(.serialized) struct GitHubReadsUrlTests {
    final class Recorder: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var seen: [(path: String, query: [String: String], body: [String: Any])] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            let url = request.url!
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            var body: [String: Any] = [:]
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                stream.close()
                body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            }
            Self.seen.append((url.path,
                              Dictionary(items.map { ($0.name, $0.value ?? "") }) { a, _ in a },
                              body))
            let reply = url.path == "/api/pr/diff"
                ? #"{"git":true,"files":[]}"# : #"{"ok":true}"#
            client?.urlProtocol(self, didReceive: HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func recording(_ run: (GitHubReads) async throws -> Void) async throws
        -> [(path: String, query: [String: String], body: [String: Any])] {
        Recorder.seen = []
        URLProtocol.registerClass(Recorder.self)
        defer { URLProtocol.unregisterClass(Recorder.self) }
        try await run(GitHubReads(baseURL: "http://127.0.0.1:1"))
        return Recorder.seen
    }

    @Test func aPrWithNoCheckoutIsReadAndWrittenByUrlAlone() async throws {
        let address = try #require(PrAddress(parsing: "https://github.com/acme/widgets/pull/42"))
        let calls = try await recording { reads in
            _ = try await reads.prDiff(cwd: address.cwd, number: 42)
            try await reads.comment(cwd: address.cwd, number: 42, body: "hi")
            try await reads.comment(cwd: address.cwd, number: 42, body: "re", replyTo: 9)
            try await reads.submitReview(cwd: address.cwd, number: 42, comments: [])
            try await reads.resolveThread(cwd: address.cwd, threadId: "PRRT_1", resolved: true)
            _ = await reads.timeline(cwd: address.cwd, number: 42, prUrl: address.url)
            _ = await reads.checks(cwd: address.cwd, number: 42)
        }
        #expect(calls.count == 7)
        for call in calls {
            #expect(call.query["cwd"] == nil && call.body["cwd"] == nil, "\(call.path) sent a cwd")
            #expect(call.query["url"] == address.url || call.body["url"] as? String == address.url,
                    "\(call.path) did not name the PR")
        }
        #expect(calls[1].body["body"] as? String == "hi")
        #expect(calls[2].body["replyTo"] as? Int == 9)
    }

    @Test func aListedPrStillNamesItsCheckoutAndNumber() async throws {
        let calls = try await recording { reads in
            _ = try await reads.prDiff(cwd: "/work/widgets", number: 42)
            try await reads.comment(cwd: "/work/widgets", number: 42, body: "hi")
        }
        #expect(calls[0].query["cwd"] == "/work/widgets")
        #expect(calls[0].query["number"] == "42")
        #expect(calls[0].query["url"] == nil)
        #expect(calls[1].body["cwd"] as? String == "/work/widgets")
        #expect(calls[1].body["number"] as? Int == 42)
    }

    @Test func rerunNeedsACheckout() async throws {
        let address = try #require(PrAddress(parsing: "https://github.com/acme/widgets/pull/42"))
        let calls = try await recording { reads in
            await #expect(throws: GitHubError.self) {
                try await reads.rerunChecks(cwd: address.cwd, number: 42, failedOnly: true)
            }
        }
        #expect(calls.isEmpty)
    }
}
