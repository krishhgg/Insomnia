import XCTest
@testable import Insomnia

private actor HeartbeatProbe {
    private var pending: [CheckedContinuation<Bool, any Error>] = []
    private(set) var calls = 0

    func run() async throws -> Bool {
        calls += 1
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func finish(_ healthy: Bool) { pending.removeFirst().resume(returning: healthy) }
}

@MainActor
final class NetworkKeepAliveTests: XCTestCase {
    func testStartIsIdempotentAndTicksDoNotOverlap() async {
        let probe = HeartbeatProbe()
        var began = 0
        var ended = 0
        let heartbeat = NetworkKeepAlive(probe: { try await probe.run() }, beginActivity: {
            began += 1
            return NSObject()
        }, endActivity: { _ in ended += 1 })
        heartbeat.tick()
        XCTAssertNil(heartbeat.task, "no traffic outside a session")
        heartbeat.start()
        heartbeat.start()
        heartbeat.tick()
        await waitForCalls(1, probe)
        XCTAssertEqual(began, 1)
        let task = heartbeat.task
        await probe.finish(true)
        await task?.value
        XCTAssertEqual(heartbeat.lastHealthy, true)
        XCTAssertNil(heartbeat.task)
        heartbeat.stop()
        heartbeat.stop()
        heartbeat.tick()
        XCTAssertNil(heartbeat.task)
        XCTAssertNil(heartbeat.lastHealthy)
        XCTAssertEqual(ended, 1)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }

    func testLateResultCannotClearNewSessionsRequest() async {
        let probe = HeartbeatProbe()
        let heartbeat = NetworkKeepAlive(probe: { try await probe.run() }, beginActivity: { NSObject() }, endActivity: { _ in })
        heartbeat.start()
        await waitForCalls(1, probe)
        let oldTask = heartbeat.task
        heartbeat.stop()
        XCTAssertTrue(oldTask?.isCancelled == true)
        heartbeat.start()
        await waitForCalls(2, probe)
        let newTask = heartbeat.task
        await probe.finish(false)
        await oldTask?.value
        XCTAssertNil(heartbeat.lastHealthy)
        XCTAssertNotNil(heartbeat.task)
        await probe.finish(true)
        await newTask?.value
        XCTAssertEqual(heartbeat.lastHealthy, true)
        heartbeat.stop()
    }

    func testFailureKeepsSessionAliveAndNextTickCanRecover() async {
        let probe = HeartbeatProbe()
        let heartbeat = NetworkKeepAlive(probe: { try await probe.run() }, beginActivity: { NSObject() }, endActivity: { _ in })
        heartbeat.start()
        await waitForCalls(1, probe)
        var task = heartbeat.task
        await probe.finish(false)
        await task?.value
        XCTAssertEqual(heartbeat.lastHealthy, false)
        heartbeat.tick()
        await waitForCalls(2, probe)
        task = heartbeat.task
        await probe.finish(true)
        await task?.value
        XCTAssertEqual(heartbeat.lastHealthy, true)
        heartbeat.stop()
    }

    private func waitForCalls(_ count: Int, _ probe: HeartbeatProbe) async {
        for _ in 0..<1000 {
            if await probe.calls == count { return }
            await Task.yield()
        }
        XCTFail("heartbeat did not start request \(count)")
    }
}
