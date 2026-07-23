import Testing

@testable import HarnessMonitorKit

@Suite("Preview harness client task board triage")
struct PreviewHarnessClientTaskBoardTriageTests {
  @Test("Preview client reads current and paginated triage history")
  func previewClientReadsTriageCurrentAndHistory() async throws {
    let client = PreviewHarnessClient(
      fixtures: .taskBoardBoardOnly,
      isLaunchAgentInstalled: true
    )
    let created = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(
        title: "Triage preview item",
        body: "Exercise triage reads.",
        priority: .medium,
        agentMode: .headless,
        tags: ["preview"]
      )
    )

    let empty = try await client.taskBoardItemTriageCurrent(id: created.id)
    #expect(empty.current == nil)

    await client.state.seedTaskBoardTriageDecisions(
      id: created.id,
      decisions: [
        sampleDecision(id: created.id, generation: 2),
        sampleDecision(id: created.id, generation: 1),
      ]
    )

    let current = try await client.taskBoardItemTriageCurrent(id: created.id)
    #expect(current.current?.generation == 2)

    let firstPage = try await client.taskBoardItemTriageHistory(
      id: created.id,
      beforeGeneration: nil,
      limit: 1
    )
    #expect(firstPage.decisions.map(\.generation) == [2])
    #expect(firstPage.nextBeforeGeneration == 2)

    let secondPage = try await client.taskBoardItemTriageHistory(
      id: created.id,
      beforeGeneration: firstPage.nextBeforeGeneration,
      limit: 1
    )
    #expect(secondPage.decisions.map(\.generation) == [1])
    #expect(secondPage.nextBeforeGeneration == nil)
  }

  @Test("Preview client rejects triage reads for an unknown item id")
  func previewClientRejectsTriageReadsForUnknownItem() async throws {
    let client = PreviewHarnessClient(
      fixtures: .taskBoardBoardOnly,
      isLaunchAgentInstalled: true
    )

    await #expect(throws: (any Error).self) {
      _ = try await client.taskBoardItemTriageCurrent(id: "missing-item")
    }
  }

  @Test("Preview client rejects invalid triage history pagination")
  func previewClientRejectsInvalidTriageHistoryPagination() async throws {
    let client = PreviewHarnessClient(
      fixtures: .taskBoardBoardOnly,
      isLaunchAgentInstalled: true
    )
    let created = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(
        title: "Triage preview item",
        body: "",
        priority: .medium,
        agentMode: .headless,
        tags: []
      )
    )

    await #expect(throws: (any Error).self) {
      _ = try await client.taskBoardItemTriageHistory(
        id: created.id,
        beforeGeneration: 0,
        limit: 1
      )
    }
    await #expect(throws: (any Error).self) {
      _ = try await client.taskBoardItemTriageHistory(
        id: created.id,
        beforeGeneration: nil,
        limit: 101
      )
    }
  }

  @Test("Deleting an item removes its triage history before an id is reused")
  func deletingItemPurgesTriageHistory() async throws {
    let client = PreviewHarnessClient(
      fixtures: .taskBoardBoardOnly,
      isLaunchAgentInstalled: true
    )
    let request = TaskBoardCreateItemRequest(
      title: "Reusable preview item",
      body: "",
      priority: .medium,
      agentMode: .headless,
      tags: []
    )
    let created = try await client.createTaskBoardItem(request: request)
    await client.state.seedTaskBoardTriageDecisions(
      id: created.id,
      decisions: [sampleDecision(id: created.id, generation: 1)]
    )

    _ = try await client.deleteTaskBoardItem(id: created.id)
    let recreated = try await client.createTaskBoardItem(request: request)
    let current = try await client.taskBoardItemTriageCurrent(id: recreated.id)

    #expect(recreated.id == created.id)
    #expect(current.current == nil)
  }

  private func sampleDecision(id: String, generation: UInt64) -> TaskBoardTriageDecisionRecord {
    TaskBoardTriageDecisionRecord(
      decisionId: "triage-\(String(format: "%032x", generation))",
      itemId: id,
      generation: generation,
      verdict: .todo,
      reasonCode: .meaningfulLabel,
      reasonDetail: nil,
      evaluatorIdentity: "task_board.triage.builtin_v1",
      evaluatorVersion: 1,
      evidenceFingerprint: "sha256:\(String(repeating: "0", count: 64))",
      cause: .initial,
      decidedAt: "2026-07-23T00:00:00Z",
      supersededAt: generation == 2 ? nil : "2026-07-23T00:01:00Z"
    )
  }
}
