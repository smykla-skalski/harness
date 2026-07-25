import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board triage rules")
struct HarnessMonitorStoreTaskBoardTriageRulesTests {
  @Test("Reads return nil without a client instead of throwing")
  func readsReturnNilWhenOffline() async throws {
    let client = RecordingHarnessClient()
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController(client: client))
    store.client = client
    store.connectionState = .offline("daemon unavailable")

    let draft = await store.taskBoardTriageRulesDraft()
    let revisions = await store.taskBoardTriageRulesRevisions()
    let audit = await store.taskBoardTriageRulesAudit()
    let preview = await store.previewTaskBoardTriageRules(
      request: TaskBoardPreviewTriageRulesRequest(rules: Self.ruleSet)
    )

    #expect(draft == nil)
    #expect(revisions == nil)
    #expect(audit == nil)
    #expect(preview == nil)
  }

  @Test("Fetches the draft and revision/audit history when online")
  func fetchesDraftAndHistoryWhenOnline() async throws {
    let client = RecordingHarnessClient()
    client.taskBoardTriageRuleSetDraftStorage = TriageRuleSetDraft(
      rules: Self.ruleSet, revision: 1, actor: "operator-1", updatedAt: "2026-07-24T00:00:00Z"
    )
    client.taskBoardTriageRuleSetRevisionsStorage = [
      TriageRuleSetRevisionSummary(
        revision: 1, schemaVersion: 1, ruleCount: 1, status: .active, actor: "operator-1",
        activatedAt: "2026-07-24T00:00:00Z")
    ]
    let store = Self.onlineStore(client: client)

    let draft = await store.taskBoardTriageRulesDraft()
    let revisions = await store.taskBoardTriageRulesRevisions()

    #expect(draft?.draft?.revision == 1)
    #expect(revisions?.revisions.map(\.revision) == [1])
  }

  @Test("Save draft persists and forwards the requested revision")
  func saveDraftPersists() async throws {
    let client = RecordingHarnessClient()
    let store = Self.onlineStore(client: client)

    let result = await store.saveTaskBoardTriageRulesDraft(
      rules: Self.ruleSet, expectedRevision: nil, actor: "operator-1"
    )

    #expect(result?.persisted == true)
    #expect(result?.revision == 1)
    #expect(client.taskBoardTriageRulesSaveDraftRequests.count == 1)
    #expect(client.taskBoardTriageRulesSaveDraftRequests[0].actor == "operator-1")
  }

  @Test("Save draft reports a stale expected revision without throwing")
  func saveDraftReportsStaleRevision() async throws {
    let client = RecordingHarnessClient()
    client.taskBoardTriageRuleSetDraftStorage = TriageRuleSetDraft(
      rules: Self.ruleSet, revision: 5, actor: "operator-1", updatedAt: "2026-07-24T00:00:00Z"
    )
    let store = Self.onlineStore(client: client)

    let result = await store.saveTaskBoardTriageRulesDraft(
      rules: Self.ruleSet, expectedRevision: 1, actor: "operator-1"
    )

    #expect(result?.persisted == false)
    #expect(result?.revision == 5)
  }

  @Test("A failed save reports nil instead of throwing")
  func saveDraftFailurePresentsFeedback() async throws {
    let client = RecordingHarnessClient()
    client.taskBoardTriageRulesError = HarnessMonitorAPIError.server(
      code: 501, message: "Triage rules unavailable"
    )
    client.taskBoardTriageRulesErrorRemainingUses = 1
    let store = Self.onlineStore(client: client)

    let result = await store.saveTaskBoardTriageRulesDraft(
      rules: Self.ruleSet, expectedRevision: nil, actor: "operator-1"
    )

    #expect(result == nil)
  }

  @Test("Activating a rule set records a new revision and refreshes the dashboard")
  func activateRecordsRevisionAndRefreshesDashboard() async throws {
    let client = RecordingHarnessClient()
    client.taskBoardItemsStorage = [Self.item(id: "task-1")]
    let store = Self.onlineStore(client: client)

    let result = await store.activateTaskBoardTriageRules(
      rules: Self.ruleSet, expectedActiveRevision: nil, actor: "operator-1"
    )

    #expect(result?.activated == true)
    #expect(result?.revision == 1)
    #expect(client.taskBoardTriageRulesActivateRequests.count == 1)
  }

  @Test("A stale expected active revision is rejected without throwing")
  func activateRejectsStaleRevision() async throws {
    let client = RecordingHarnessClient()
    client.activeTriageRuleSetRevisionStorage = 3
    let store = Self.onlineStore(client: client)

    let result = await store.activateTaskBoardTriageRules(
      rules: Self.ruleSet, expectedActiveRevision: 1, actor: "operator-1"
    )

    #expect(result?.activated == false)
    #expect(result?.revision == 3)
  }

  @Test("Deactivating passes nil rules through to the client request")
  func deactivatePassesNilRules() async throws {
    let client = RecordingHarnessClient()
    client.activeTriageRuleSetRevisionStorage = 1
    client.taskBoardTriageRuleSetRevisionsStorage = [
      TriageRuleSetRevisionSummary(
        revision: 1, schemaVersion: 1, ruleCount: 1, status: .active, actor: "operator-1",
        activatedAt: "2026-07-24T00:00:00Z")
    ]
    let store = Self.onlineStore(client: client)

    let result = await store.activateTaskBoardTriageRules(
      rules: nil, expectedActiveRevision: 1, actor: "operator-1"
    )

    #expect(result?.activated == true)
    #expect(client.taskBoardTriageRulesActivateRequests[0].rules == nil)
  }

  private static var ruleSet: TriageRuleSetV1 {
    TriageRuleSetV1(
      schemaVersion: 1,
      rules: [
        TriageRule(
          id: "urgent-bugs",
          when: [.priorityEquals(priority: .critical)],
          outcome: TriageRuleOutcome(verdict: .todo)
        )
      ],
      defaultOutcome: TriageRuleOutcome(verdict: .undecided)
    )
  }

  private static func onlineStore(client: RecordingHarnessClient) -> HarnessMonitorStore {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController(client: client))
    store.client = client
    store.connectionState = .online
    return store
  }

  private static func item(id: String) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Fixture board item",
      body: "",
      status: .todo,
      priority: .medium,
      tags: [],
      projectId: nil,
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-07-23T00:00:00Z",
      updatedAt: "2026-07-23T00:01:00Z",
      deletedAt: nil
    )
  }
}
