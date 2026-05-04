import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("HarnessMonitorStore agent timeline partition")
struct HarnessMonitorStoreAgentTimelinePartitionTests {
  @Test("timeline(forAgent:) returns only entries with that agentId")
  @MainActor
  func partitionsByAgentId() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.timeline = [
      makeEntry(id: "a-1", agentId: "agent-alpha"),
      makeEntry(id: "b-1", agentId: "agent-beta"),
      makeEntry(id: "a-2", agentId: "agent-alpha"),
      makeEntry(id: "n-1", agentId: nil),
    ]

    let alpha = store.timeline(forAgent: "agent-alpha")
    let beta = store.timeline(forAgent: "agent-beta")
    let missing = store.timeline(forAgent: "agent-gamma")

    #expect(alpha.map(\.entryId) == ["a-1", "a-2"])
    #expect(beta.map(\.entryId) == ["b-1"])
    #expect(missing.isEmpty)
  }

  @Test("partition rebuilds when timeline is replaced")
  @MainActor
  func rebuildsOnReplace() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.timeline = [makeEntry(id: "a-1", agentId: "agent-alpha")]
    #expect(store.timeline(forAgent: "agent-alpha").map(\.entryId) == ["a-1"])

    store.timeline = [makeEntry(id: "b-1", agentId: "agent-beta")]
    #expect(store.timeline(forAgent: "agent-alpha").isEmpty)
    #expect(store.timeline(forAgent: "agent-beta").map(\.entryId) == ["b-1"])
  }

  @Test("partition preserves source ordering inside each agent slice")
  @MainActor
  func preservesOrdering() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.timeline = [
      makeEntry(id: "a-3", agentId: "agent-alpha"),
      makeEntry(id: "a-1", agentId: "agent-alpha"),
      makeEntry(id: "a-2", agentId: "agent-alpha"),
    ]
    #expect(store.timeline(forAgent: "agent-alpha").map(\.entryId) == ["a-3", "a-1", "a-2"])
  }

  private func makeEntry(id: String, agentId: String?) -> TimelineEntry {
    TimelineEntry(
      entryId: id,
      recordedAt: "2026-05-04T10:00:00Z",
      kind: "tool_call",
      sessionId: "session-fixture",
      agentId: agentId,
      taskId: nil,
      summary: "fixture entry \(id)",
      payload: .object([:])
    )
  }
}
