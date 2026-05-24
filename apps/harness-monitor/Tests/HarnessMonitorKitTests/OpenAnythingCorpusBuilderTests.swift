import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("OpenAnything corpus builder")
struct OpenAnythingCorpusBuilderTests {
  @Test("Empty input still emits action and window records")
  func emptyInputEmitsStaticRecords() {
    let records = OpenAnythingCorpusBuilder.records(input: Self.input())

    let domains = Set(records.map(\.domain))
    #expect(domains.contains(.actions))
    #expect(domains.contains(.windows))
  }

  @Test("PolicyCanvas action and window stay hidden when the flag is off")
  func policyCanvasLabGateRespected() {
    let off = OpenAnythingCorpusBuilder.records(
      input: Self.input(showsPolicyCanvasLab: false)
    )
    let on = OpenAnythingCorpusBuilder.records(
      input: Self.input(showsPolicyCanvasLab: true)
    )

    let offTargets = off.map(\.target)
    let onTargets = on.map(\.target)

    #expect(!offTargets.contains(where: Self.isPolicyCanvasLabAction))
    #expect(!offTargets.contains(where: Self.isPolicyCanvasLabWindow))
    #expect(onTargets.contains(where: Self.isPolicyCanvasLabAction))
    #expect(onTargets.contains(where: Self.isPolicyCanvasLabWindow))
  }

  @Test("Suggested actions stay marked across rebuilds")
  func suggestedActionsRoundTrip() {
    let records = OpenAnythingCorpusBuilder.records(input: Self.input())
    let suggestedIDs = records.filter(\.isSuggested).map(\.id)

    #expect(suggestedIDs.contains("action.newSession"))
    #expect(suggestedIDs.contains("action.openTaskBoard"))
    #expect(suggestedIDs.contains("action.openReviews"))
    #expect(suggestedIDs.contains("action.openDiagnostics"))
    #expect(suggestedIDs.contains("action.refresh"))
  }

  @Test("Action records do not duplicate dashboard-route records")
  func actionRecordsNoLongerDuplicateRouteRecords() {
    let records = OpenAnythingCorpusBuilder.records(input: Self.input())

    let actionTargets = records.filter { $0.domain == .actions }.map(\.target)
    let windowTargets = records.filter { $0.domain == .windows }.map(\.target)

    let windowDashboardRoutes = windowTargets.compactMap { target -> OpenAnythingDashboardRoute? in
      if case .dashboardRoute(let route) = target { return route }
      return nil
    }
    let actionDashboardOpens = actionTargets.compactMap { target -> OpenAnythingAction? in
      if case .action(let action) = target { return action }
      return nil
    }

    // The duplicate-route bug surfaced rows like "Open Board" (action) and
    // "Board" (windows.dashboardRoute) that resolved to the same step. After
    // Unit 2 there are no dashboardRoute records at all - the actions branch
    // is the sole entry point for dashboard sub-routes.
    #expect(windowDashboardRoutes.isEmpty)
    #expect(actionDashboardOpens.contains(.openTaskBoard))
    #expect(actionDashboardOpens.contains(.openReviews))
  }

  @Test("Loaded timeline corpus keeps only the most recent 200 entries")
  func loadedTimelineRecordsKeepRecentWindow() {
    let timeline = (0..<250).reversed().map { index in
      Self.timelineEntry(index: index)
    }
    let records = OpenAnythingCorpusBuilder.records(
      input: Self.input(
        loadedSession: OpenAnythingLoadedSessionSnapshot(
          sessionID: "session-a",
          agents: [],
          tasks: [],
          timeline: timeline
        )
      )
    )

    let timelineIDs =
      records
      .filter { $0.domain == .loadedSession }
      .map(\.id)

    #expect(timelineIDs.count == 200)
    #expect(timelineIDs.first == "loadedSession.timeline.session-a.entry-249")
    #expect(timelineIDs.last == "loadedSession.timeline.session-a.entry-050")
    #expect(!timelineIDs.contains("loadedSession.timeline.session-a.entry-049"))
  }

  @Test("Loaded timeline corpus handles chronological store order")
  func loadedTimelineRecordsHandleChronologicalStoreOrder() {
    let timeline = (0..<250).map { index in
      Self.timelineEntry(index: index)
    }
    let records = OpenAnythingCorpusBuilder.records(
      input: Self.input(
        loadedSession: OpenAnythingLoadedSessionSnapshot(
          sessionID: "session-a",
          agents: [],
          tasks: [],
          timeline: timeline
        )
      )
    )

    let timelineIDs =
      records
      .filter { $0.domain == .loadedSession }
      .map(\.id)

    #expect(timelineIDs.count == 200)
    #expect(timelineIDs.first == "loadedSession.timeline.session-a.entry-249")
    #expect(timelineIDs.last == "loadedSession.timeline.session-a.entry-050")
    #expect(!timelineIDs.contains("loadedSession.timeline.session-a.entry-049"))
  }

  @Test("Loaded timeline tie ordering matches store timeline order")
  func loadedTimelineRecordsUseStableTieOrdering() {
    let recordedAt = "2026-05-23T12:00:00Z"
    let timeline = [
      Self.timelineEntry(entryID: "entry-b", recordedAt: recordedAt),
      Self.timelineEntry(entryID: "entry-c", recordedAt: recordedAt),
      Self.timelineEntry(entryID: "entry-a", recordedAt: recordedAt),
    ]
    let records = OpenAnythingCorpusBuilder.records(
      input: Self.input(
        loadedSession: OpenAnythingLoadedSessionSnapshot(
          sessionID: "session-a",
          agents: [],
          tasks: [],
          timeline: timeline
        )
      )
    )

    let timelineIDs =
      records
      .filter { $0.domain == .loadedSession }
      .map(\.id)

    #expect(
      timelineIDs == [
        "loadedSession.timeline.session-a.entry-a",
        "loadedSession.timeline.session-a.entry-b",
        "loadedSession.timeline.session-a.entry-c",
      ]
    )
  }

  @Test("Corpus source signature tracks record-affecting source fields")
  func sourceSignatureTracksRecordFields() {
    let base = Self.input()
    let titleChanged = Self.input(
      settingsSections: [
        OpenAnythingSettingsSectionProjection(
          rawValue: "general",
          title: "General Updated",
          systemImage: "gearshape"
        )
      ]
    )

    #expect(
      OpenAnythingCorpusSourceSignature.compute(base)
        != OpenAnythingCorpusSourceSignature.compute(titleChanged)
    )
  }

  @Test("Plugin registry reports whether plugins are registered")
  func pluginRegistryReportsRegisteredState() {
    let registry = OpenAnythingPluginRegistry()

    #expect(!registry.hasRegisteredPlugins)

    registry.register(Self.TestPlugin(id: "test"))

    #expect(registry.hasRegisteredPlugins)

    registry.unregister(id: "test")

    #expect(!registry.hasRegisteredPlugins)
  }

  private static func input(
    settingsSections: [OpenAnythingSettingsSectionProjection] = [
      OpenAnythingSettingsSectionProjection(
        rawValue: "general",
        title: "General",
        systemImage: "gearshape"
      )
    ],
    loadedSession: OpenAnythingLoadedSessionSnapshot? = nil,
    showsPolicyCanvasLab: Bool = true
  ) -> OpenAnythingCorpusInput {
    OpenAnythingCorpusInput(
      settingsSections: settingsSections,
      sessions: [],
      taskBoardItems: [],
      decisions: [],
      reviews: [],
      loadedSession: loadedSession,
      showsPolicyCanvasLab: showsPolicyCanvasLab
    )
  }

  private static func timelineEntry(index: Int) -> TimelineEntry {
    timelineEntry(
      entryID: String(format: "entry-%03d", index),
      recordedAt: String(format: "2026-05-23T12:%03d:00Z", index),
      summary: "Entry \(index)"
    )
  }

  private static func timelineEntry(
    entryID: String,
    recordedAt: String,
    summary: String = "Entry"
  ) -> TimelineEntry {
    TimelineEntry(
      entryId: entryID,
      recordedAt: recordedAt,
      kind: "event",
      sessionId: "session-a",
      agentId: nil,
      taskId: nil,
      summary: summary,
      payload: .null
    )
  }

  private static func isPolicyCanvasLabAction(_ target: OpenAnythingTarget) -> Bool {
    if case .action(.policyCanvasLab) = target { return true }
    return false
  }

  private static func isPolicyCanvasLabWindow(_ target: OpenAnythingTarget) -> Bool {
    if case .window(.policyCanvasLab) = target { return true }
    return false
  }

  private struct TestPlugin: OpenAnythingPlugin {
    let id: String

    func records(input _: OpenAnythingCorpusInput) -> [OpenAnythingRecord] {
      []
    }
  }
}
