import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("SessionTimeline filtering")
struct SessionTimelineFilterTests {
  @Test("Node builder extracts semantic properties and raw payload keys")
  func nodeBuilderExtractsSemanticPropertiesAndRawPayloadKeys() {
    let decision = makeDecision(
      id: "decision-1",
      fixture: .init(
        severity: .critical,
        sessionID: "session-1",
        agentID: "alpha",
        taskID: "task-1",
        actions: [
          SuggestedAction(
            id: "dismiss-decision-1",
            title: "Dismiss",
            kind: .dismiss,
            payloadJSON: "{}"
          )
        ]
      )
    )
    let entry = TimelineEntry(
      entryId: "entry-1",
      recordedAt: "2026-04-14T10:00:00Z",
      kind: "tool_result_error",
      sessionId: "session-1",
      agentId: "alpha",
      taskId: "task-1",
      summary: "Alpha received an error from Search",
      payload: .object([
        "supervisor": .object([
          "decision_id": .string("decision-1")
        ]),
        "tool_call_timeline": .object([
          "tool_call_id": .string("call-1"),
          "status": .string("failed"),
          "capability_tags": .array([.string("fs"), .string("shell")]),
          "stop_reason": .string("timeout"),
        ]),
        "event": .object([
          "tool_name": .string("Search")
        ]),
      ])
    )

    let nodes = SessionTimelineNodeBuilder(
      sessionID: "session-1",
      entries: [entry],
      decisions: [decision]
    )
    .build()

    let entryNode = nodes.first { $0.id == "entry:entry-1" }
    #expect(entryNode?.kind == .linkedDecision)
    #expect(entryNode?.semanticProperties.contains(.linkedDecision) == true)
    #expect(entryNode?.semanticProperties.contains(.toolCall) == true)
    #expect(entryNode?.semanticProperties.contains(.agent) == true)
    #expect(entryNode?.semanticProperties.contains(.task) == true)
    #expect(entryNode?.semanticProperties.contains(.capabilityTags) == true)
    #expect(entryNode?.semanticProperties.contains(.stopReason) == true)
    #expect(entryNode?.semanticProperties.contains(.decisionAction) == true)
    #expect(entryNode?.rawPayloadKeys.contains("supervisor") == true)
    #expect(entryNode?.rawPayloadKeys.contains("supervisor.decision_id") == true)
    #expect(entryNode?.rawPayloadKeys.contains("tool_call_timeline") == true)
    #expect(entryNode?.rawPayloadKeys.contains("tool_call_timeline.stop_reason") == true)
    #expect(entryNode?.rawPayloadKeys.contains("event") == true)
    #expect(entryNode?.rawPayloadKeys.contains("event.tool_name") == true)
  }

  @Test("Filter snapshot narrows rows by tone, type, agent, properties, and query")
  @MainActor
  func filterSnapshotNarrowsRowsByMultipleFacets() {
    let matchingNode = SessionTimelineNode(
      identity: .entry("entry-match"),
      kind: .event,
      timestamp: Date(timeIntervalSince1970: 1_900_000_001),
      rawTimestamp: nil,
      sourceLabel: "task_checkpoint",
      entryKind: "task_checkpoint",
      title: "Beta warned about timeout",
      detail: "Task task-2",
      agentID: "beta",
      taskID: "task-2",
      eventTone: .warning,
      decision: nil,
      semanticProperties: [.agent, .task],
      rawPayloadKeys: ["supervisor.reason"]
    )
    let filteredOutByType = SessionTimelineNode(
      identity: .entry("entry-other"),
      kind: .event,
      timestamp: Date(timeIntervalSince1970: 1_900_000_002),
      rawTimestamp: nil,
      sourceLabel: "tool_result",
      entryKind: "tool_result",
      title: "Beta completed Search",
      detail: nil,
      agentID: "beta",
      taskID: "task-2",
      eventTone: .warning,
      decision: nil,
      semanticProperties: [.agent],
      rawPayloadKeys: ["event.tool_name"]
    )
    let filteredOutByAgent = SessionTimelineNode(
      identity: .entry("entry-alpha"),
      kind: .event,
      timestamp: Date(timeIntervalSince1970: 1_900_000_003),
      rawTimestamp: nil,
      sourceLabel: "task_checkpoint",
      entryKind: "task_checkpoint",
      title: "Alpha warned about timeout",
      detail: "Task task-1",
      agentID: "alpha",
      taskID: "task-1",
      eventTone: .warning,
      decision: nil,
      semanticProperties: [.agent, .task],
      rawPayloadKeys: ["supervisor.reason"]
    )

    let filters = SessionTimelineFilterState(
      query: "beta",
      searchScope: .all,
      tones: [.warning],
      eventTypes: ["task_checkpoint"],
      agents: ["beta"],
      tasks: [],
      decisionSeverities: [],
      semanticProperties: [.agent],
      rawPayloadKeys: ["supervisor.reason"]
    )
    let snapshot = SessionTimelineFilterSnapshot(
      nodes: [matchingNode, filteredOutByType, filteredOutByAgent],
      filters: filters,
      configuration: .default
    )

    #expect(snapshot.filteredNodeCount == 1)
    #expect(snapshot.rows.map(\.id) == [matchingNode.id])
    #expect(snapshot.summary.statusText == "6 filters • 1 match in 3 loaded items")
  }

  @Test("Filter inventory counts respect the other active facets")
  @MainActor
  func filterInventoryCountsRespectOtherActiveFacets() {
    let betaWarning = SessionTimelineNode(
      identity: .entry("entry-beta-warning"),
      kind: .event,
      timestamp: Date(timeIntervalSince1970: 1_900_000_011),
      rawTimestamp: nil,
      sourceLabel: "task_checkpoint",
      entryKind: "task_checkpoint",
      title: "Beta warning",
      detail: nil,
      agentID: "beta",
      taskID: "task-1",
      eventTone: .warning,
      decision: nil,
      semanticProperties: [.agent],
      rawPayloadKeys: []
    )
    let betaCritical = SessionTimelineNode(
      identity: .entry("entry-beta-critical"),
      kind: .event,
      timestamp: Date(timeIntervalSince1970: 1_900_000_012),
      rawTimestamp: nil,
      sourceLabel: "tool_result_error",
      entryKind: "tool_result_error",
      title: "Beta critical",
      detail: nil,
      agentID: "beta",
      taskID: "task-2",
      eventTone: .critical,
      decision: nil,
      semanticProperties: [.agent],
      rawPayloadKeys: []
    )
    let alphaWarning = SessionTimelineNode(
      identity: .entry("entry-alpha-warning"),
      kind: .event,
      timestamp: Date(timeIntervalSince1970: 1_900_000_013),
      rawTimestamp: nil,
      sourceLabel: "task_checkpoint",
      entryKind: "task_checkpoint",
      title: "Alpha warning",
      detail: nil,
      agentID: "alpha",
      taskID: "task-3",
      eventTone: .warning,
      decision: nil,
      semanticProperties: [.agent],
      rawPayloadKeys: []
    )

    let filters = SessionTimelineFilterState(
      query: "",
      searchScope: .all,
      tones: [.warning],
      eventTypes: [],
      agents: ["beta"],
      tasks: [],
      decisionSeverities: [],
      semanticProperties: [],
      rawPayloadKeys: []
    )
    let snapshot = SessionTimelineFilterSnapshot(
      nodes: [betaWarning, betaCritical, alphaWarning],
      filters: filters,
      configuration: .default
    )

    #expect(snapshot.filteredNodeCount == 1)
    #expect(snapshot.inventory.count(for: .warning) == 1)
    #expect(snapshot.inventory.count(for: .critical) == 1)
    let toolResultErrorCount =
      snapshot.inventory.eventTypes.first { $0.id == "tool_result_error" }?.count ?? 0
    #expect(
      snapshot.inventory.eventTypes.first(where: { $0.id == "task_checkpoint" })?.count == 1
    )
    #expect(toolResultErrorCount == 0)
  }

  @Test("Tone filters count toward the Filters button active state")
  func toneFiltersCountTowardTheFiltersButtonActiveState() {
    var filters = SessionTimelineFilterState()

    #expect(filters.activeAdvancedFilterCount == 0)

    filters.toggleTone(.warning)
    #expect(filters.activeAdvancedFilterCount == 1)

    filters.toggleTone(.critical)
    #expect(filters.activeAdvancedFilterCount == 2)

    filters.clearTones()
    #expect(filters.activeAdvancedFilterCount == 0)
  }

  @Test("Visibility stats switch to filtered match wording")
  func visibilityStatsSwitchToFilteredMatchWording() {
    let stats = SessionTimelineVisibilityStats(
      visibleRowCount: 3,
      renderedRowCount: 3,
      loadedEventCount: 24,
      totalEventCount: 321,
      filteredMatchCount: 8,
      firstVisibleMatchNumber: 2,
      lastVisibleMatchNumber: 4
    )

    #expect(stats.statusText == "Showing 2-4 of 8 matches")
    #expect(
      stats.accessibilityStatusText
        == "Showing matching timeline items 2 to 4 of 8"
    )
  }

  @Test("Stored filter registry round-trips by session")
  func storedFilterRegistryRoundTripsBySession() {
    let state = SessionTimelineFilterState(
      query: "search",
      searchScope: .properties,
      tones: [.critical],
      eventTypes: ["tool_result_error"],
      agents: ["alpha"],
      tasks: ["task-1"],
      decisionSeverities: ["critical"],
      semanticProperties: [.toolCall, .stopReason],
      rawPayloadKeys: ["event.tool_name", "tool_call_timeline.stop_reason"]
    )
    var registry = SessionTimelineStoredFilterRegistry()
    registry.set(state, for: "session-1")

    let encoded = registry.encodedString()
    let decoded = encoded.map(SessionTimelineStoredFilterRegistry.decode(from:))

    #expect(decoded?.state(for: "session-1") == state)
  }

  @Test("Filter persistence hydration respects storage mode")
  func filterPersistenceHydrationRespectsStorageMode() {
    let appState = SessionTimelineFilterState(
      query: "app search",
      searchScope: .summary,
      tones: [.critical],
      eventTypes: [],
      agents: ["app-agent"],
      tasks: [],
      decisionSeverities: [],
      semanticProperties: [],
      rawPayloadKeys: []
    )
    let windowState = SessionTimelineFilterState(
      query: "window search",
      searchScope: .properties,
      tones: [],
      eventTypes: ["tool_result_error"],
      agents: [],
      tasks: ["task-9"],
      decisionSeverities: ["warning"],
      semanticProperties: [.toolCall],
      rawPayloadKeys: ["event.tool_name"]
    )
    var registry = SessionTimelineStoredFilterRegistry()
    registry.set(windowState, for: "session-2")
    let input = SessionTimelineFilterHydrationInput(
      sessionID: "session-2",
      appStateRawValue: appState.encodedString() ?? "",
      sceneRegistryRawValue: registry.encodedString() ?? ""
    )

    #expect(
      SessionTimelineFilterPersistenceResolver.hydrate(mode: .ephemeral, input: input) == .init()
    )
    #expect(
      SessionTimelineFilterPersistenceResolver.hydrate(mode: .application, input: input) == appState
    )
    #expect(
      SessionTimelineFilterPersistenceResolver.hydrate(mode: .sessionWindow, input: input)
        == windowState
    )
  }

  @Test("Filter persistence writes only the active storage bucket")
  func filterPersistenceWritesOnlyTheActiveStorageBucket() {
    let existingAppState = SessionTimelineFilterState(
      query: "existing app",
      searchScope: .all,
      tones: [.info],
      eventTypes: [],
      agents: [],
      tasks: [],
      decisionSeverities: [],
      semanticProperties: [],
      rawPayloadKeys: []
    )
    let existingWindowState = SessionTimelineFilterState(
      query: "existing window",
      searchScope: .agent,
      tones: [],
      eventTypes: ["task_checkpoint"],
      agents: ["window-agent"],
      tasks: [],
      decisionSeverities: [],
      semanticProperties: [.agent],
      rawPayloadKeys: []
    )
    let currentState = SessionTimelineFilterState(
      query: "current",
      searchScope: .task,
      tones: [.warning],
      eventTypes: [],
      agents: ["beta"],
      tasks: ["task-2"],
      decisionSeverities: [],
      semanticProperties: [.task],
      rawPayloadKeys: ["supervisor.reason"]
    )
    var registry = SessionTimelineStoredFilterRegistry()
    registry.set(existingWindowState, for: "session-2")
    let appRawValue = existingAppState.encodedString() ?? ""
    let sceneRawValue = registry.encodedString() ?? ""

    let applicationPersisted = SessionTimelineFilterPersistenceResolver.persist(
      mode: .application,
      state: currentState,
      sessionID: "session-2",
      appStateRawValue: appRawValue,
      sceneRegistryRawValue: sceneRawValue
    )
    #expect(applicationPersisted.appStateRawValue == (currentState.encodedString() ?? ""))
    #expect(applicationPersisted.sceneRegistryRawValue == sceneRawValue)

    let sessionWindowPersisted = SessionTimelineFilterPersistenceResolver.persist(
      mode: .sessionWindow,
      state: currentState,
      sessionID: "session-2",
      appStateRawValue: appRawValue,
      sceneRegistryRawValue: sceneRawValue
    )
    #expect(sessionWindowPersisted.appStateRawValue == appRawValue)
    #expect(
      SessionTimelineStoredFilterRegistry
        .decode(from: sessionWindowPersisted.sceneRegistryRawValue)
        .state(for: "session-2") == currentState
    )

    let ephemeralPersisted = SessionTimelineFilterPersistenceResolver.persist(
      mode: .ephemeral,
      state: currentState,
      sessionID: "session-2",
      appStateRawValue: appRawValue,
      sceneRegistryRawValue: sceneRawValue
    )
    #expect(ephemeralPersisted.appStateRawValue == appRawValue)
    #expect(ephemeralPersisted.sceneRegistryRawValue == sceneRawValue)
  }
}
