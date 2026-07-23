import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task board triage inspector state")
struct TaskBoardTriageInspectorStateTests {
  @Test("A clean draft adopts the freshly loaded reason")
  func cleanDraftAdoptsReason() async throws {
    let (inspector, item) = try await Self.loadedInspector()
    #expect(inspector.overrideReasonDraft == "")

    inspector.receive(
      Self.response(reason: "needs a second pass"), itemID: item.id,
      token: inspector.currentToken())

    #expect(inspector.overrideReasonDraft == "needs a second pass")
  }

  @Test("A draft that already matches the server reason still adopts cleanly")
  func matchingDraftAdoptsReason() async throws {
    let (inspector, item) = try await Self.loadedInspector()
    inspector.overrideReasonDraft = "same text"

    inspector.receive(
      Self.response(reason: "same text"), itemID: item.id, token: inspector.currentToken())

    #expect(inspector.overrideReasonDraft == "same text")
  }

  @Test("A divergent typed draft survives a same-item refresh")
  func dirtyDraftSurvivesRefresh() async throws {
    let (inspector, item) = try await Self.loadedInspector()
    inspector.receive(
      Self.response(reason: "original"), itemID: item.id, token: inspector.currentToken())
    inspector.overrideReasonDraft = "still typing"

    inspector.receive(
      Self.response(reason: "changed elsewhere"), itemID: item.id, token: inspector.currentToken())

    #expect(inspector.overrideReasonDraft == "still typing")
  }

  @Test("A viewer-redacted actor never seeds its reason into the draft")
  func redactedActorNeverSeedsReason() async throws {
    let (inspector, item) = try await Self.loadedInspector()

    inspector.receive(
      Self.response(reason: "not visible to a viewer", actor: "[redacted]"), itemID: item.id,
      token: inspector.currentToken())
    #expect(inspector.overrideReasonDraft == "")

    inspector.overrideReasonDraft = "typed before the redacted refresh landed"
    inspector.receive(
      Self.response(reason: "still not visible", actor: "[redacted]"), itemID: item.id,
      token: inspector.currentToken())

    #expect(inspector.overrideReasonDraft == "typed before the redacted refresh landed")
  }

  @Test("A stale fence token or a mismatched item id is ignored")
  func staleFenceIsIgnored() async throws {
    let (inspector, item) = try await Self.loadedInspector()
    inspector.overrideReasonDraft = "untouched"

    inspector.receive(
      Self.response(reason: "stale token"), itemID: item.id,
      token: inspector.currentToken() - 1)
    #expect(inspector.overrideReasonDraft == "untouched")

    inspector.receive(
      Self.response(reason: "wrong item"), itemID: "item-2", token: inspector.currentToken())
    #expect(inspector.overrideReasonDraft == "untouched")
  }

  @Test("Loading exposes no override, then a loaded response replaces it")
  func loadingThenLoadedTransition() async throws {
    let (inspector, _) = try await Self.loadedInspector()

    #expect(inspector.hasLoadedResponse)
    #expect(!inspector.isLoading)
    #expect(!inspector.didFail)
  }

  @Test("An offline load reports failure, not a loaded empty response")
  func offlineLoadReportsFailure() async {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    store.connectionState = .offline("daemon unavailable")
    let item = Self.item(id: "item-1")
    store.globalTaskBoardItems = [item]
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)
    let inspector = TaskBoardTriageInspectorState()

    await inspector.load(item: item, actions: actions)

    #expect(inspector.didFail)
    #expect(!inspector.hasLoadedResponse)
    #expect(!inspector.isLoading)
  }

  @Test("Mutation refresh suppresses the duplicate updated-item load")
  func mutationRefreshSuppressesDuplicateLoad() async throws {
    let (inspector, item) = try await Self.loadedInspector()
    let token = inspector.beginMutation(itemID: item.id)
    inspector.receive(
      Self.response(reason: "recorded once"),
      itemID: item.id,
      itemUpdatedAt: item.updatedAt,
      token: token
    )
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    store.connectionState = .online
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)

    await inspector.load(item: item, actions: actions)

    #expect(inspector.current?.triageOverride?.reason == "recorded once")
  }

  @Test("History loads in bounded pages and appends older decisions")
  func historyLoadsBoundedPages() async throws {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    store.connectionState = .online
    let client = try #require(store.client as? PreviewHarnessClient)
    let item = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(
        title: "History fixture",
        body: "",
        priority: .medium,
        agentMode: .interactive,
        tags: ["triage/ready"]
      )
    )
    await client.state.seedTaskBoardTriageDecisions(
      id: item.id,
      decisions: (1...21).reversed().map { Self.decision(itemID: item.id, generation: $0) }
    )
    store.globalTaskBoardItems = [item]
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)
    let inspector = TaskBoardTriageInspectorState()
    await inspector.load(item: item, actions: actions)

    await inspector.loadHistory(item: item, actions: actions, reset: true)
    #expect(inspector.historyDecisions.count == 20)
    #expect(inspector.historyNextBeforeGeneration == 2)

    await inspector.loadHistory(item: item, actions: actions, reset: false)
    #expect(inspector.historyDecisions.map(\.generation) == Array((1...21).reversed()))
    #expect(inspector.historyNextBeforeGeneration == nil)
  }

  @Test("Only active remote writers may mutate triage overrides")
  func remoteAuthorizationMatchesDaemonWriteScope() throws {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)
    #expect(actions.canMutateTaskBoardTriageOverride)

    store.remoteDaemonProfile = try Self.remoteProfile(role: .viewer, scopes: ["read"])
    #expect(!actions.canMutateTaskBoardTriageOverride)

    store.remoteDaemonProfile = try Self.remoteProfile(role: .operator, scopes: ["read"])
    #expect(!actions.canMutateTaskBoardTriageOverride)

    store.remoteDaemonProfile = try Self.remoteProfile(
      role: .operator,
      scopes: ["read", "write"]
    )
    #expect(actions.canMutateTaskBoardTriageOverride)
  }

  /// A fresh inspector's `itemID` is `nil`, so `receive` against it directly
  /// would fence out every response and pass vacuously -- seed through the
  /// real `load()` path instead. The item must exist through the store's
  /// own client, not just `globalTaskBoardItems`, or the read 404s and the
  /// load reports `.failed` regardless of `connectionState`.
  private static func loadedInspector() async throws -> (
    TaskBoardTriageInspectorState, TaskBoardItem
  ) {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    store.connectionState = .online
    let created = try await store.client!.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(
        title: "Fixture board item", body: "", priority: .medium, agentMode: .headless, tags: [])
    )
    store.globalTaskBoardItems = [created]
    let actions = TaskBoardOverviewActions(store: store, scope: .dashboard)
    let inspector = TaskBoardTriageInspectorState()
    await inspector.load(item: created, actions: actions)
    return (inspector, created)
  }

  private static func response(
    reason: String?, actor: String = "operator-1"
  ) -> TaskBoardTriageCurrentResponse {
    TaskBoardTriageCurrentResponse(
      current: nil,
      triageOverride: TaskBoardTriageOverride(
        verdict: .todo, actor: actor, reason: reason, setAt: "2026-07-23T00:00:00Z"),
      effective: TaskBoardTriageEffectiveOutcome(verdict: .todo, source: .override)
    )
  }

  private static func decision(
    itemID: String,
    generation: Int
  ) -> TaskBoardTriageDecisionRecord {
    TaskBoardTriageDecisionRecord(
      decisionId: "triage-\(String(format: "%032x", generation))",
      itemId: itemID,
      generation: UInt64(generation),
      verdict: generation.isMultiple(of: 2) ? .todo : .undecided,
      reasonCode: generation.isMultiple(of: 2) ? .meaningfulLabel : .noMeaningfulLabels,
      reasonDetail: generation.isMultiple(of: 2) ? "triage/ready" : nil,
      evaluatorIdentity: "task_board.triage.builtin_v1",
      evaluatorVersion: 1,
      evidenceFingerprint: "sha256:\(String(repeating: "0", count: 64))",
      cause: generation == 1 ? .initial : .fingerprintChanged,
      decidedAt: "2026-07-23T00:00:00Z",
      supersededAt: generation == 21 ? nil : "2026-07-23T00:01:00Z"
    )
  }

  private static func remoteProfile(
    role: RemoteDaemonRole,
    scopes: [String]
  ) throws -> RemoteDaemonProfile {
    RemoteDaemonProfile(
      id: UUID(),
      endpoint: try #require(URL(string: "https://daemon.example.com")),
      clientID: "triage-inspector-test",
      displayName: "Triage inspector test",
      platform: "macos",
      role: role,
      scopes: scopes,
      serverSPKISHA256: try RemoteDaemonSPKIPin(
        validating: "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="
      ),
      tokenHint: "abcd1234",
      pairedAt: Date(timeIntervalSince1970: 0),
      pairingExpiresAt: Date(timeIntervalSince1970: 60),
      status: .active,
      revokedAt: nil
    )
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
