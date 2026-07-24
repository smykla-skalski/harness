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

  @Test("Set preserves an already-congruent BuiltInV1 producer")
  func setAgreeingWithExistingBuiltInPlacementPreservesProducer() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
    let created = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(
        title: "Congruent placement", body: "", priority: .medium, agentMode: .headless,
        tags: ["kind/bug"]))

    var snapshot = try await client.taskBoardItemPositionSnapshot(id: created.id)
    _ = try await client.setTaskBoardItemTriageOverride(
      id: created.id,
      request: TaskBoardSetTriageOverrideRequest(
        verdict: .todo, expectedItemRevision: snapshot.itemRevision,
        expectedItemsChangeSeq: snapshot.itemsChangeSeq, actor: "operator-1"))
    snapshot = try await client.taskBoardItemPositionSnapshot(id: created.id)
    _ = try await client.clearTaskBoardItemTriageOverride(
      id: created.id,
      request: TaskBoardClearTriageOverrideRequest(
        expectedItemRevision: snapshot.itemRevision,
        expectedItemsChangeSeq: snapshot.itemsChangeSeq, actor: "operator-1"))
    snapshot = try await client.taskBoardItemPositionSnapshot(id: created.id)
    #expect(snapshot.item.laneOrigin == .automatic(producer: "task_board.triage.builtin_v1"))

    let result = try await client.setTaskBoardItemTriageOverride(
      id: created.id,
      request: TaskBoardSetTriageOverrideRequest(
        verdict: .todo, expectedItemRevision: snapshot.itemRevision,
        expectedItemsChangeSeq: snapshot.itemsChangeSeq, actor: "operator-1"))

    #expect(result.snapshot.item.laneOrigin == .automatic(producer: "task_board.triage.builtin_v1"))
  }

  @Test("Clear appends fingerprint_changed then active_evaluator_changed generations")
  func clearAppendsFingerprintThenEvaluatorChangedGenerations() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
    let created = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(
        title: "Evidence drift", body: "original body", priority: .medium, agentMode: .headless,
        tags: []))

    var snapshot = try await client.taskBoardItemPositionSnapshot(id: created.id)
    _ = try await client.setTaskBoardItemTriageOverride(
      id: created.id,
      request: TaskBoardSetTriageOverrideRequest(
        verdict: .todo, expectedItemRevision: snapshot.itemRevision,
        expectedItemsChangeSeq: snapshot.itemsChangeSeq, actor: "operator-1"))
    snapshot = try await client.taskBoardItemPositionSnapshot(id: created.id)
    _ = try await client.clearTaskBoardItemTriageOverride(
      id: created.id,
      request: TaskBoardClearTriageOverrideRequest(
        expectedItemRevision: snapshot.itemRevision,
        expectedItemsChangeSeq: snapshot.itemsChangeSeq, actor: "operator-1"))

    _ = try await client.updateTaskBoardItem(
      id: created.id, request: TaskBoardUpdateItemRequest(body: "changed body"))
    snapshot = try await client.taskBoardItemPositionSnapshot(id: created.id)
    _ = try await client.setTaskBoardItemTriageOverride(
      id: created.id,
      request: TaskBoardSetTriageOverrideRequest(
        verdict: .todo, expectedItemRevision: snapshot.itemRevision,
        expectedItemsChangeSeq: snapshot.itemsChangeSeq, actor: "operator-1"))
    snapshot = try await client.taskBoardItemPositionSnapshot(id: created.id)
    _ = try await client.clearTaskBoardItemTriageOverride(
      id: created.id,
      request: TaskBoardClearTriageOverrideRequest(
        expectedItemRevision: snapshot.itemRevision,
        expectedItemsChangeSeq: snapshot.itemsChangeSeq, actor: "operator-1"))

    let afterEvidenceChange = try await client.taskBoardItemTriageHistory(id: created.id)
    #expect(afterEvidenceChange.decisions.map(\.generation) == [2, 1])
    #expect(afterEvidenceChange.decisions[0].cause == .fingerprintChanged)
    #expect(afterEvidenceChange.decisions[1].supersededAt != nil)

    await client.state.seedTaskBoardTriageDecisions(
      id: created.id,
      decisions: [
        TaskBoardTriageDecisionRecord(
          decisionId: "triage-mismatch", itemId: created.id, generation: 2,
          verdict: afterEvidenceChange.decisions[0].verdict,
          reasonCode: afterEvidenceChange.decisions[0].reasonCode, reasonDetail: nil,
          evaluatorIdentity: "task_board.triage.other_evaluator", evaluatorVersion: 1,
          evidenceFingerprint: afterEvidenceChange.decisions[0].evidenceFingerprint,
          cause: .initial, decidedAt: "2026-07-23T00:00:00Z", supersededAt: nil)
      ])
    snapshot = try await client.taskBoardItemPositionSnapshot(id: created.id)
    _ = try await client.setTaskBoardItemTriageOverride(
      id: created.id,
      request: TaskBoardSetTriageOverrideRequest(
        verdict: .todo, expectedItemRevision: snapshot.itemRevision,
        expectedItemsChangeSeq: snapshot.itemsChangeSeq, actor: "operator-1"))
    snapshot = try await client.taskBoardItemPositionSnapshot(id: created.id)
    _ = try await client.clearTaskBoardItemTriageOverride(
      id: created.id,
      request: TaskBoardClearTriageOverrideRequest(
        expectedItemRevision: snapshot.itemRevision,
        expectedItemsChangeSeq: snapshot.itemsChangeSeq, actor: "operator-1"))

    let afterEvaluatorMismatch = try await client.taskBoardItemTriageHistory(id: created.id)
    #expect(afterEvaluatorMismatch.decisions[0].generation == 3)
    #expect(afterEvaluatorMismatch.decisions[0].cause == .activeEvaluatorChanged)
  }

  @Test("Decision id and fingerprint are canonically shaped and order/duplicate invariant")
  func decisionIdAndFingerprintAreCanonicalAndOrderInvariant() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
    let itemA = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(
        title: "Shape check", body: "", priority: .medium, agentMode: .headless,
        tags: ["kind/bug", "area/ui", "kind/bug"]))
    let itemB = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(
        title: "Shape check", body: "", priority: .medium, agentMode: .headless,
        tags: ["area/ui", "kind/bug"]))

    let decisionA = try await Self.revealDecision(for: itemA.id, using: client)
    let decisionB = try await Self.revealDecision(for: itemB.id, using: client)

    let hex = decisionA.decisionId.dropFirst("triage-".count)
    #expect(decisionA.decisionId.hasPrefix("triage-"))
    #expect(hex.count == 32)
    #expect(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })

    let fingerprintHex = decisionA.evidenceFingerprint?.dropFirst("sha256:".count) ?? ""
    #expect(decisionA.evidenceFingerprint?.hasPrefix("sha256:") == true)
    #expect(fingerprintHex.count == 64)
    #expect(fingerprintHex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    #expect(
      decisionA.evidenceFingerprint == decisionB.evidenceFingerprint,
      "duplicate/reordered labels must not change the fingerprint")
  }

  private static func revealDecision(
    for id: String, using client: PreviewHarnessClient
  ) async throws -> TaskBoardTriageDecisionRecord {
    var snapshot = try await client.taskBoardItemPositionSnapshot(id: id)
    _ = try await client.setTaskBoardItemTriageOverride(
      id: id,
      request: TaskBoardSetTriageOverrideRequest(
        verdict: .todo, expectedItemRevision: snapshot.itemRevision,
        expectedItemsChangeSeq: snapshot.itemsChangeSeq, actor: "operator-1"))
    snapshot = try await client.taskBoardItemPositionSnapshot(id: id)
    _ = try await client.clearTaskBoardItemTriageOverride(
      id: id,
      request: TaskBoardClearTriageOverrideRequest(
        expectedItemRevision: snapshot.itemRevision,
        expectedItemsChangeSeq: snapshot.itemsChangeSeq, actor: "operator-1"))
    let history = try await client.taskBoardItemTriageHistory(id: id)
    return try #require(history.decisions.first)
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
