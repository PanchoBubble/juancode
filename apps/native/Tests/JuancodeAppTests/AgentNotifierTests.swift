import Testing
import UserNotifications
@testable import JuancodeApp

@Suite @MainActor struct AgentNotifierTests {
    @MainActor final class Delivery {
        var permission: CheckedContinuation<Bool, Never>?
        var requested: CheckedContinuation<Void, Never>?
        var requests: [UNNotificationRequest] = []
        var removed: [String] = []
        var authorizationCount = 0

        func notifier() -> AgentNotifier {
            AgentNotifier(authorize: {
                self.authorizationCount += 1
                return await withCheckedContinuation { continuation in
                    self.permission = continuation
                    self.requested?.resume()
                    self.requested = nil
                }
            }, submit: { self.requests.append($0) }, remove: { self.removed.append($0) })
        }

        func waitForPermissionRequest() async {
            if permission != nil { return }
            await withCheckedContinuation { requested = $0 }
        }
    }

    @Test func firstQuestionWaitsForPermission() async throws {
        let delivery = Delivery()
        let notifier = delivery.notifier()
        let task = notifier.post(sessionId: "question", title: "Agent", subtitle: "repo",
                                 body: "Waiting for your input", critical: true)
        await delivery.waitForPermissionRequest()
        #expect(delivery.requests.isEmpty)
        delivery.permission?.resume(returning: true)
        await task.value
        let request = try #require(delivery.requests.first)
        #expect(request.identifier == "juancode.agent.question")
        #expect(request.content.userInfo["sessionId"] as? String == "question")
        #expect(request.content.interruptionLevel == .timeSensitive)
        #expect(request.content.sound == .default)
    }

    @Test func deniedPermissionDoesNotSubmit() async {
        let delivery = Delivery()
        let notifier = delivery.notifier()
        let task = notifier.post(sessionId: "a", title: "Agent", subtitle: "", body: "Question", critical: true)
        await delivery.waitForPermissionRequest()
        delivery.permission?.resume(returning: false)
        await task.value
        #expect(delivery.requests.isEmpty)
    }

    @Test func viewingSessionDuringPermissionDialogCancelsAlert() async {
        let delivery = Delivery()
        let notifier = delivery.notifier()
        let task = notifier.post(sessionId: "a", title: "Agent", subtitle: "", body: "Question", critical: true)
        await delivery.waitForPermissionRequest()
        notifier.clear(sessionId: "a")
        delivery.permission?.resume(returning: true)
        await task.value
        #expect(delivery.requests.isEmpty)
        #expect(delivery.removed == ["juancode.agent.a"])
    }

    @Test func newerQuestionReplacesPendingTurnEnd() async {
        let delivery = Delivery()
        let notifier = delivery.notifier()
        let old = notifier.post(sessionId: "a", title: "Agent", subtitle: "", body: "Done", critical: false)
        await delivery.waitForPermissionRequest()
        let new = notifier.post(sessionId: "a", title: "Agent", subtitle: "", body: "Question", critical: true)
        delivery.permission?.resume(returning: true)
        await old.value
        await new.value
        #expect(delivery.authorizationCount == 1)
        #expect(delivery.requests.map { $0.content.body } == ["Question"])
    }
}
