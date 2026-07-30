import XCTest
@testable import JuancodeServices

/// The heavy-queue registry reader: ordering, entry decoding, and the priority
/// rewrites the panel performs. Nothing is spawned — the queue is a directory of
/// JSON files, so a temp root is a complete fake.
final class HeavyQueueTests: XCTestCase {
    private var root: URL!
    private var config: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heavy-queue-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("queue"), withIntermediateDirectories: true)
        config = root.appendingPathComponent("heavy-queue.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A queue where every pid is considered alive unless listed in `dead`.
    private func queue(dead: Set<Int> = [], command: String? = "cmd") -> HeavyQueue {
        HeavyQueue(root: root, configPath: config,
                   isAlive: { !dead.contains($0) },
                   commandForPid: { _ in command })
    }

    private func writeEntry(pid: Int, prio: Int = 0, since: Int = 0, slot: Int = 0,
                            cmd: String = "pnpm test", cwd: String = "/repo/pandora") throws {
        let obj: [String: Any] = [
            "pid": pid, "prio": prio, "since": since, "slot": slot,
            "cmd": cmd, "cwd": cwd, "child": NSNull(),
        ]
        try JSONSerialization.data(withJSONObject: obj)
            .write(to: root.appendingPathComponent("queue/\(pid).json"))
    }

    private func writeSlot(_ n: Int, pid: Int) throws {
        let dir = root.appendingPathComponent("slot-\(n)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "\(pid)\n".write(to: dir.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
    }

    // MARK: - Ordering

    func testWaitingOrdersByPriorityThenAge() {
        let jobs = [
            HeavyJob(pid: 1, prio: 0, since: 100),
            HeavyJob(pid: 2, prio: 5, since: 300),
            HeavyJob(pid: 3, prio: 0, since: 50),
            HeavyJob(pid: 4, prio: 5, since: 200),
        ]
        let (running, waiting) = HeavyQueue.order(jobs)
        XCTAssertTrue(running.isEmpty)
        XCTAssertEqual(waiting.map(\.pid), [4, 2, 3, 1])
    }

    func testRunningSplitsOutAndSortsBySlot() {
        let jobs = [
            HeavyJob(pid: 1, prio: 9, since: 10),
            HeavyJob(pid: 2, since: 20, slot: 2),
            HeavyJob(pid: 3, since: 30, slot: 1),
        ]
        let (running, waiting) = HeavyQueue.order(jobs)
        XCTAssertEqual(running.map(\.pid), [3, 2])
        XCTAssertEqual(waiting.map(\.pid), [1])
    }

    // MARK: - Reading

    func testSnapshotSkipsDeadEntriesAndReadsCapacity() throws {
        try writeEntry(pid: 11, slot: 1)
        try writeEntry(pid: 22, prio: 3, since: 200)
        try writeEntry(pid: 33, since: 100) // dead: its wrapper is gone
        try Data(#"{"slots":2,"workerCap":6}"#.utf8).write(to: config)

        let snap = queue(dead: [33]).snapshot()
        XCTAssertEqual(snap.slots, 2)
        XCTAssertEqual(snap.workerCap, 6)
        XCTAssertEqual(snap.running.map(\.pid), [11])
        XCTAssertEqual(snap.waiting.map(\.pid), [22])
        XCTAssertEqual(snap.total, 2)
    }

    func testCapacityFallsBackToWrapperDefaults() {
        let (slots, cap) = queue().capacity()
        XCTAssertEqual(slots, 1)
        XCTAssertEqual(cap, 4)
    }

    func testSlotHolderWithoutEntryIsStillReported() throws {
        try writeSlot(1, pid: 777)
        let snap = queue(command: "/bin/zsh heavy pnpm test").snapshot()
        XCTAssertEqual(snap.running.map(\.pid), [777])
        XCTAssertEqual(snap.running.first?.cmd, "/bin/zsh heavy pnpm test")
    }

    func testSlotHolderWithAnEntryIsNotDuplicated() throws {
        try writeEntry(pid: 777, slot: 1)
        try writeSlot(1, pid: 777)
        XCTAssertEqual(queue().snapshot().running.count, 1)
    }

    func testDeadSlotHolderIsIgnored() throws {
        try writeSlot(1, pid: 777)
        XCTAssertTrue(queue(dead: [777]).snapshot().isEmpty)
    }

    func testDecodeIgnoresGarbage() {
        XCTAssertNil(HeavyQueue.decode(nil))
        XCTAssertNil(HeavyQueue.decode(Data("{".utf8)))
        XCTAssertNil(HeavyQueue.decode(Data(#"{"prio":1}"#.utf8)))
    }

    // MARK: - Writing

    func testSetPriorityRewritesOnlyThePriority() throws {
        try writeEntry(pid: 42, prio: 0, since: 900, cmd: "pnpm build")
        XCTAssertTrue(queue().setPriority(pid: 42, to: 7))

        let job = try XCTUnwrap(queue().snapshot().waiting.first)
        XCTAssertEqual(job.prio, 7)
        XCTAssertEqual(job.since, 900)
        XCTAssertEqual(job.cmd, "pnpm build")
    }

    func testSetPriorityOnAMissingEntryFails() {
        XCTAssertFalse(queue().setPriority(pid: 999, to: 1))
    }

    func testMoveToFrontBeatsTheBestQueuedPriority() throws {
        try writeEntry(pid: 1, prio: 4, since: 10)
        try writeEntry(pid: 2, prio: 0, since: 20)
        let q = queue()
        XCTAssertEqual(q.moveToFront(pid: 2, in: q.snapshot()), 5)
        XCTAssertEqual(q.snapshot().waiting.map(\.pid), [2, 1])
    }

    func testNudgeUpPastAnEquallyPrioritisedNeighbour() throws {
        try writeEntry(pid: 1, prio: 0, since: 10)
        try writeEntry(pid: 2, prio: 0, since: 20)
        let q = queue()
        q.nudge(pid: 2, up: true, in: q.snapshot())
        XCTAssertEqual(q.snapshot().waiting.map(\.pid), [2, 1])
    }

    func testNudgeSwapsWithAHigherPrioritisedNeighbour() throws {
        try writeEntry(pid: 1, prio: 5, since: 10)
        try writeEntry(pid: 2, prio: 1, since: 20)
        let q = queue()
        q.nudge(pid: 2, up: true, in: q.snapshot())
        let after = q.snapshot().waiting
        XCTAssertEqual(after.map(\.pid), [2, 1])
        XCTAssertEqual(after.map(\.prio), [5, 1])
    }

    func testNudgeAtTheEdgeIsANoOp() throws {
        try writeEntry(pid: 1, prio: 0, since: 10)
        try writeEntry(pid: 2, prio: 0, since: 20)
        let q = queue()
        q.nudge(pid: 1, up: true, in: q.snapshot())
        q.nudge(pid: 2, up: false, in: q.snapshot())
        XCTAssertEqual(q.snapshot().waiting.map(\.pid), [1, 2])
    }
}
