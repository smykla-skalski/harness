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

  // Property check: the partition cache must agree with the linear-scan
  // reference on every agentId for any random timeline shape we hand it.
  // The linear scan IS the contract; the cache is the fast implementation.
  @Test("partition agrees with linear-scan reference for randomized inputs")
  @MainActor
  func matchesLinearScanReference() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let agentIDs = ["agent-alpha", "agent-beta", "agent-gamma"]
    var rng = SystemRandomNumberGenerator()

    for trial in 0..<32 {
      let length = Int.random(in: 0..<48, using: &rng)
      let timeline: [TimelineEntry] = (0..<length).map { idx in
        let agent = Bool.random(using: &rng) ? agentIDs.randomElement(using: &rng) : nil
        return makeEntry(id: "t\(trial)-e\(idx)", agentId: agent)
      }
      store.timeline = timeline

      for agentID in agentIDs {
        let cached = store.timeline(forAgent: agentID).map(\.entryId)
        let reference = timeline.filter { $0.agentId == agentID }.map(\.entryId)
        #expect(cached == reference)
      }

      let unknown = store.timeline(forAgent: "agent-not-present")
      #expect(unknown.isEmpty, "agent ids absent from timeline must return empty slice")
    }
  }

  // Negative-path: SwiftUI `@Observable` array writes via append still go
  // through the property setter (Swift value semantics rebuild the storage),
  // so didSet must fire and the partition must rebuild. If a future refactor
  // hides the array behind a reference type or a copy-on-write that bypasses
  // the setter, this test goes red and surfaces the missing invalidation.
  @Test("partition rebuilds when timeline is mutated via append, not just whole-array replacement")
  @MainActor
  func rebuildsOnAppendMutation() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.timeline = [makeEntry(id: "a-1", agentId: "agent-alpha")]
    #expect(store.timeline(forAgent: "agent-alpha").map(\.entryId) == ["a-1"])

    store.timeline.append(makeEntry(id: "b-1", agentId: "agent-beta"))
    #expect(store.timeline(forAgent: "agent-alpha").map(\.entryId) == ["a-1"])
    #expect(store.timeline(forAgent: "agent-beta").map(\.entryId) == ["b-1"])

    store.timeline.append(makeEntry(id: "a-2", agentId: "agent-alpha"))
    #expect(store.timeline(forAgent: "agent-alpha").map(\.entryId) == ["a-1", "a-2"])
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
