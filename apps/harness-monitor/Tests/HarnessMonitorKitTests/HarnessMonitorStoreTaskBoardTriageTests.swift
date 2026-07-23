import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board triage reads")
struct HarnessMonitorStoreTaskBoardTriageTests {
  @Test("Fetches the current decision when online")
  func fetchesCurrentDecisionWhenOnline() async throws {
    let client = RecordingHarnessClient()
    client.taskBoardTriageDecisionsStorage["task-1"] = [
      TaskBoardTriageDecisionRecord(
        decisionId: "triage-00000000000000000000000000000000",
        itemId: "task-1",
        generation: 1,
        verdict: .todo,
        reasonCode: .meaningfulLabel,
        reasonDetail: nil,
        evaluatorIdentity: "task_board.triage.builtin_v1",
        evaluatorVersion: 1,
        evidenceFingerprint:
          "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        cause: .initial,
        decidedAt: "2026-07-23T00:00:00Z",
        supersededAt: nil
      )
    ]
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController(client: client))
    store.client = client
    store.connectionState = .online

    let response = await store.taskBoardItemTriageCurrent(id: "task-1")

    #expect(response?.current?.generation == 1)
  }

  @Test("Returns nil without a client instead of throwing")
  func returnsNilWhenOffline() async throws {
    let client = RecordingHarnessClient()
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController(client: client))
    store.client = client
    store.connectionState = .offline("daemon unavailable")

    let current = await store.taskBoardItemTriageCurrent(id: "task-1")
    let history = await store.taskBoardItemTriageHistory(id: "task-1")

    #expect(current == nil)
    #expect(history == nil)
  }

  @Test("Recording client purges triage history when an id is reused")
  func recordingClientPurgesTriageHistoryOnDelete() async throws {
    let client = RecordingHarnessClient()
    let request = TaskBoardCreateItemRequest(
      title: "Reusable recording item",
      body: "",
      priority: .medium,
      agentMode: .headless,
      tags: []
    )
    let created = try await client.createTaskBoardItem(request: request)
    client.taskBoardTriageDecisionsStorage[created.id] = [
      TaskBoardTriageDecisionRecord(
        decisionId: "triage-00000000000000000000000000000000",
        itemId: created.id,
        generation: 1,
        verdict: .todo,
        reasonCode: .meaningfulLabel,
        reasonDetail: nil,
        evaluatorIdentity: "task_board.triage.builtin_v1",
        evaluatorVersion: 1,
        evidenceFingerprint:
          "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        cause: .initial,
        decidedAt: "2026-07-23T00:00:00Z",
        supersededAt: nil
      )
    ]

    _ = try await client.deleteTaskBoardItem(id: created.id)
    let recreated = try await client.createTaskBoardItem(request: request)
    let current = try await client.taskBoardItemTriageCurrent(id: recreated.id)

    #expect(recreated.id == created.id)
    #expect(current.current == nil)
  }
}
