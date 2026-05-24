import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
extension SessionWindowRouteContentSelectionTests {
  @Test("Toolbar search only mirrors into decision filters when decisions consume the query")
  func toolbarSearchMirrorIsDecisionRouteScoped() {
    let agentsTrigger = SessionWindowSearchMirrorPolicy.trigger(
      renderedRoute: .agents,
      appSearchQuery: "worker"
    )
    #expect(agentsTrigger.shouldMirrorDecisionQuery == false)
    #expect(agentsTrigger.query.isEmpty)
    #expect(
      SessionWindowSearchMirrorPolicy.decisionQueryUpdate(
        from: .init(shouldMirrorDecisionQuery: false, query: ""),
        to: agentsTrigger
      ) == nil
    )

    let decisionsWithQuery = SessionWindowSearchMirrorPolicy.trigger(
      renderedRoute: .decisions,
      appSearchQuery: "worker"
    )
    #expect(decisionsWithQuery.shouldMirrorDecisionQuery)
    #expect(decisionsWithQuery.query == "worker")
    #expect(
      SessionWindowSearchMirrorPolicy.decisionQueryUpdate(
        from: agentsTrigger,
        to: decisionsWithQuery
      ) == "worker"
    )

    let decisionsEmptyOnEntry = SessionWindowSearchMirrorPolicy.trigger(
      renderedRoute: .decisions,
      appSearchQuery: ""
    )
    #expect(
      SessionWindowSearchMirrorPolicy.decisionQueryUpdate(
        from: agentsTrigger,
        to: decisionsEmptyOnEntry
      ) == nil
    )
    #expect(
      SessionWindowSearchMirrorPolicy.decisionQueryUpdate(
        from: decisionsWithQuery,
        to: decisionsEmptyOnEntry
      )?.isEmpty == true
    )
    #expect(
      SessionWindowSearchMirrorPolicy.decisionQueryUpdate(
        from: decisionsWithQuery,
        to: agentsTrigger
      )?.isEmpty == true
    )
  }

  @Test("Toolbar search only mirrors into timeline filters on the timeline route")
  func toolbarSearchMirrorIsTimelineRouteScoped() {
    let cockpitTrigger = SessionTimelineSearchMirrorPolicy.trigger(
      isEnabled: false,
      appSearchQuery: "signal"
    )
    #expect(cockpitTrigger.isEnabled == false)
    #expect(cockpitTrigger.query.isEmpty)
    #expect(
      SessionTimelineSearchMirrorPolicy.filterQueryUpdate(
        from: .init(isEnabled: false, query: ""),
        to: cockpitTrigger
      ) == nil
    )

    let timelineWithQuery = SessionTimelineSearchMirrorPolicy.trigger(
      isEnabled: true,
      appSearchQuery: "signal"
    )
    #expect(timelineWithQuery.isEnabled)
    #expect(timelineWithQuery.query == "signal")
    #expect(
      SessionTimelineSearchMirrorPolicy.filterQueryUpdate(
        from: cockpitTrigger,
        to: timelineWithQuery
      ) == "signal"
    )

    let timelineEmptyOnEntry = SessionTimelineSearchMirrorPolicy.trigger(
      isEnabled: true,
      appSearchQuery: ""
    )
    #expect(
      SessionTimelineSearchMirrorPolicy.filterQueryUpdate(
        from: cockpitTrigger,
        to: timelineEmptyOnEntry
      )?.isEmpty == true
    )
    #expect(
      SessionTimelineSearchMirrorPolicy.filterQueryUpdate(
        from: timelineWithQuery,
        to: cockpitTrigger
      )?.isEmpty == true
    )
  }

  @Test("Task detail pane avoids nested grouped Form inside the session scroll surface")
  func taskDetailPaneAvoidsNestedGroupedForm() throws {
    let taskDetail = try sourceFile(named: "SessionTaskDetailPane.swift")

    #expect(
      taskDetail.contains("SessionDetailScrollSurface(contentPadding: metrics.contentPadding)")
    )
    #expect(taskDetail.contains("SessionDetailPanel(title: \"Task\")"))
    #expect(taskDetail.contains("SessionDetailFactsGrid("))
    #expect(!taskDetail.contains("Form {"))
    #expect(!taskDetail.contains(".harnessNativeFormContainer()"))
    #expect(!taskDetail.contains(".scrollDisabled(true)"))
  }

  @Test("Wrap layout preserves its cache across unchanged subview updates")
  func wrapLayoutPreservesCacheAcrossUnchangedSubviews() throws {
    let wrapLayout = try sourceFile(named: "../Shared/HarnessMonitorWrapLayout.swift")

    #expect(wrapLayout.contains("func updateCache(_: inout Cache, subviews _: Subviews)"))
    #expect(wrapLayout.contains("resetting here only defeats the cache"))
    #expect(wrapLayout.contains("let spacing: CGFloat"))
    #expect(wrapLayout.contains("let lineSpacing: CGFloat"))
    #expect(!wrapLayout.contains("cache = Cache()"))
  }

}

extension SessionWindowRouteContentSelectionTests {
  func sessionRouteContentSource() throws -> String {
    try [
      "SessionWindowRouteContent.swift",
      "SessionWindowRouteContent+Tasks.swift",
      "SessionWindowRouteContent+Decisions.swift",
    ]
    .map { try sourceFile(named: $0) }
    .joined(separator: "\n")
  }

  func sourceFile(named name: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    let sourceURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor/Sources/HarnessMonitorUIPreviewable/Views/Sessions"
      )
      .appendingPathComponent(name)

    return try String(
      contentsOf: sourceURL,
      encoding: .utf8
    )
  }

  func agent(id: String, name: String) -> AgentRegistration {
    AgentRegistration(
      agentId: id,
      name: name,
      runtime: "codex",
      role: .worker,
      capabilities: [],
      joinedAt: "2026-05-01T17:00:00Z",
      updatedAt: "2026-05-01T17:00:01Z",
      status: .active,
      agentSessionId: nil,
      managedAgent: nil,
      lastActivityAt: nil,
      currentTaskId: nil,
      runtimeCapabilities: RuntimeCapabilities(
        runtime: "codex",
        supportsNativeTranscript: true,
        supportsSignalDelivery: true,
        supportsContextInjection: true,
        typicalSignalLatencySeconds: 5,
        hookPoints: []
      ),
      persona: nil
    )
  }

  func task(id: String, title: String, context: String?) -> WorkItem {
    WorkItem(
      taskId: id,
      title: title,
      context: context,
      severity: .medium,
      status: .open,
      assignedTo: nil,
      createdAt: "2026-05-01T17:00:00Z",
      updatedAt: "2026-05-01T17:00:01Z",
      createdBy: nil,
      notes: [],
      suggestedFix: nil,
      source: .manual,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: nil
    )
  }
}
