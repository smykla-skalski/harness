import Testing

@testable import HarnessMonitorKit

/// Deliberately not `@MainActor`: the recording path is only worth testing when
/// the calls genuinely overlap, and a main-actor suite would serialize them and
/// pass against a racy implementation.
@Suite("Recording client call recording")
struct RecordingHarnessClientCallRecordingTests {
  private let concurrentCallCount = 200

  @Test("Concurrent calls all reach the recorded call list")
  func concurrentCallsAllReachTheRecordedCallList() async throws {
    let client = RecordingHarnessClient()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<concurrentCallCount {
        group.addTask {
          // The recorded calls never suspend, so without this the group can
          // drain tasks one at a time and the racy implementation survives.
          await Task.yield()
          if index.isMultiple(of: 2) {
            _ = try await client.startTaskBoardOrchestrator()
          } else {
            _ = try await client.stopTaskBoardOrchestrator()
          }
        }
      }
      try await group.waitForAll()
    }

    let calls = client.recordedCalls()
    #expect(calls.count == concurrentCallCount)
    #expect(calls.filter { $0 == .startTaskBoardOrchestrator }.count == concurrentCallCount / 2)
    #expect(calls.filter { $0 == .stopTaskBoardOrchestrator }.count == concurrentCallCount / 2)
  }

  @Test("Clearing recorded calls leaves later concurrent recordings intact")
  func clearingRecordedCallsLeavesLaterConcurrentRecordingsIntact() async throws {
    let client = RecordingHarnessClient()
    client.record(.startTaskBoardOrchestrator)
    client.clearRecordedCalls()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<concurrentCallCount {
        group.addTask {
          await Task.yield()
          _ = try await client.stopTaskBoardOrchestrator()
        }
      }
      try await group.waitForAll()
    }

    let expected = Array(
      repeating: RecordingHarnessClient.Call.stopTaskBoardOrchestrator,
      count: concurrentCallCount
    )
    #expect(client.recordedCalls() == expected)
  }
}
