import AppKit
import CoreGraphics
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionTimelineNavigationTests {
  @Test("Programmatic scroll to edges still publishes edge entries")
  @MainActor
  func programmaticScrollToEdgesStillPublishesEdgeEntries() async throws {
    let viewport = SessionTimelineViewportModel()
    var topEdgeEntryCount = 0
    var bottomEdgeEntryCount = 0
    let coordinator = SessionTimelineTableView.Coordinator(
      viewport: viewport,
      scrollBoundaryChanged: { oldValue, newValue in
        if newValue.enteredTopEdge(from: oldValue) {
          topEdgeEntryCount += 1
        }
        if newValue.enteredBottomEdge(from: oldValue) {
          bottomEdgeEntryCount += 1
        }
      }
    )
    defer { coordinator.cancelMeasurement(reason: "test") }

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 945, height: 260))
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = false

    let tableView = NSTableView(frame: scrollView.bounds)
    tableView.headerView = nil
    tableView.backgroundColor = .clear
    tableView.intercellSpacing = .zero
    tableView.usesAutomaticRowHeights = false

    let column = NSTableColumn(identifier: SessionTimelineTableCellView.columnIdentifier)
    column.width = 945
    tableView.addTableColumn(column)
    tableView.delegate = coordinator
    tableView.dataSource = coordinator
    scrollView.documentView = tableView
    scrollView.contentView.postsBoundsChangedNotifications = true
    coordinator.configure(tableView: tableView, scrollView: scrollView)

    let rows = makeTimelineRows(count: 14)
    coordinator.update(
      rows: rows,
      actionHandler: NullDecisionActionHandler(),
      onSignalTap: nil,
      scrollCommand: nil,
      request: .init(scrollView: scrollView, columnWidth: 945, fontScale: 1)
    )
    coordinator.cancelMeasurement(reason: "test")
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    try #require(coordinator.scrollToTarget(rows.last!.id))
    await Task.yield()
    await Task.yield()

    #expect(bottomEdgeEntryCount == 1)

    try #require(coordinator.scrollToTarget(rows.first!.id))
    await Task.yield()
    await Task.yield()

    #expect(topEdgeEntryCount == 1)
  }

  @Test("Replacing rows publishes bottom edge when loaded rows fit the viewport")
  @MainActor
  func replacingRowsPublishesBottomEdgeWhenLoadedRowsFitViewport() async throws {
    let viewport = SessionTimelineViewportModel()
    var bottomEdgeEntryCount = 0
    let coordinator = SessionTimelineTableView.Coordinator(
      viewport: viewport,
      scrollBoundaryChanged: { oldValue, newValue in
        if newValue.enteredBottomEdge(from: oldValue) {
          bottomEdgeEntryCount += 1
        }
      }
    )
    defer { coordinator.cancelMeasurement(reason: "test") }

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 945, height: 470))
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = false

    let tableView = NSTableView(frame: scrollView.bounds)
    tableView.headerView = nil
    tableView.backgroundColor = .clear
    tableView.intercellSpacing = .zero
    tableView.usesAutomaticRowHeights = false

    let column = NSTableColumn(identifier: SessionTimelineTableCellView.columnIdentifier)
    column.width = 945
    tableView.addTableColumn(column)
    tableView.delegate = coordinator
    tableView.dataSource = coordinator
    scrollView.documentView = tableView
    scrollView.contentView.postsBoundsChangedNotifications = true
    coordinator.configure(tableView: tableView, scrollView: scrollView)

    coordinator.update(
      rows: makeTimelineRows(count: 4),
      actionHandler: NullDecisionActionHandler(),
      onSignalTap: nil,
      scrollCommand: nil,
      request: .init(scrollView: scrollView, columnWidth: 945, fontScale: 1)
    )
    coordinator.cancelMeasurement(reason: "test")
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    await Task.yield()
    await Task.yield()

    #expect(bottomEdgeEntryCount == 1)
  }

  @Test("Bottom edge callback requests the next older timeline window")
  @MainActor
  func bottomEdgeCallbackRequestsNextOlderTimelineWindow() async throws {
    let fixture = await makeBottomEdgeRequestFixture()
    let summary = fixture.summary
    let store = fixture.store

    await store.selectSession(summary.sessionId)
    let initialWindowSize = HarnessMonitorStore.initialSelectedTimelineWindowLimit
    #expect(store.timeline.count == initialWindowSize)
    #expect(store.timelineWindow?.windowStart == 0)
    #expect(store.timelineWindow?.windowEnd == initialWindowSize)
    #expect(store.timelineWindow?.hasOlder == true)
    let presentation = SessionTimelineSectionPresentation(
      sessionID: summary.sessionId,
      timeline: store.timeline,
      timelineWindow: store.timelineWindow,
      decisions: [],
      signals: [],
      filters: .init(),
      isTimelineLoading: false,
      reduceMotion: false,
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      dateTimeConfiguration: .default
    )
    #expect(presentation.navigation.totalCount == fixture.fullTimeline.count)
    #expect(presentation.navigation.windowEnd == initialWindowSize)
    #expect(presentation.navigation.hasOlder == true)
    #expect(presentation.navigation.isLoading == false)
    #expect(presentation.fallbackVisibleRowCount > 0)
    let view = SessionTimelineView(
      style: .cockpitSection,
      host: .session(summary.sessionId),
      timeline: store.timeline,
      timelineWindow: store.timelineWindow,
      decisions: [],
      isTimelineLoading: false,
      store: store
    )

    let oldBoundaryState = SessionTimelineScrollBoundaryState(
      visibleMinY: 260,
      visibleMaxY: 560,
      contentHeight: 1_200
    )
    let newBoundaryState = SessionTimelineScrollBoundaryState(
      visibleMinY: 760,
      visibleMaxY: 1_060,
      contentHeight: 1_200
    )
    #expect(newBoundaryState.enteredBottomEdge(from: oldBoundaryState))
    let computedLimit = SessionTimelineEdgeLoadPolicy.limit(
      for: .older,
      context: SessionTimelineEdgeLoadContext(
        navigation: presentation.navigation,
        visibleRowCount: 0,
        viewportRowCapacity: 0,
        fallbackVisibleRowCount: presentation.fallbackVisibleRowCount
      ),
      from: oldBoundaryState,
      to: newBoundaryState
    )
    #expect(computedLimit == 2)
    let didRequest = view.requestOlderWindowIfNeeded(
      presentation,
      from: oldBoundaryState,
      to: newBoundaryState
    )
    #expect(didRequest)

    for _ in 0..<20 {
      if fixture.client.recordedTimelineWindowRequests(for: summary.sessionId).count > 1 {
        break
      }
      try await Task.sleep(for: .milliseconds(5))
    }

    #expect(
      fixture.client.recordedTimelineWindowRequests(for: summary.sessionId).suffix(1) == [
        TimelineWindowRequest(
          scope: .summary,
          limit: 2,
          before: TimelineCursor(
            recordedAt: fixture.fullTimeline[initialWindowSize - 1].recordedAt,
            entryId: fixture.fullTimeline[initialWindowSize - 1].entryId
          )
        )
      ]
    )
  }

  @Test("Bottom edge callback waits for the active timeline load")
  @MainActor
  func bottomEdgeCallbackWaitsForActiveTimelineLoad() async throws {
    let fixture = await makeBottomEdgeRequestFixture()
    let summary = fixture.summary
    let store = fixture.store

    await store.selectSession(summary.sessionId)
    let presentation = SessionTimelineSectionPresentation(
      sessionID: summary.sessionId,
      timeline: store.timeline,
      timelineWindow: store.timelineWindow,
      decisions: [],
      signals: [],
      filters: .init(),
      isTimelineLoading: true,
      reduceMotion: false,
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      dateTimeConfiguration: .default
    )
    let view = SessionTimelineView(
      style: .cockpitSection,
      host: .session(summary.sessionId),
      timeline: store.timeline,
      timelineWindow: store.timelineWindow,
      decisions: [],
      isTimelineLoading: true,
      store: store
    )
    let requestCount = fixture.client.recordedTimelineWindowRequests(
      for: summary.sessionId
    ).count
    let didRequest = view.requestOlderWindowIfNeeded(
      presentation,
      from: SessionTimelineScrollBoundaryState(
        visibleMinY: 260,
        visibleMaxY: 560,
        contentHeight: 1_200
      ),
      to: SessionTimelineScrollBoundaryState(
        visibleMinY: 760,
        visibleMaxY: 1_060,
        contentHeight: 1_200
      )
    )

    #expect(didRequest == false)
    #expect(
      fixture.client.recordedTimelineWindowRequests(for: summary.sessionId).count
        == requestCount
    )
  }

  @Test("Session window edge load uses its snapshot instead of selected timeline")
  @MainActor
  func sessionWindowEdgeLoadUsesSnapshotTimeline() async throws {
    let fixture = await makeBottomEdgeRequestFixture()
    let summary = fixture.summary
    let store = fixture.store
    let initialWindowSize = HarnessMonitorStore.initialSelectedTimelineWindowLimit
    let initialWindow = try await fixture.client.timelineWindow(
      sessionID: summary.sessionId,
      request: .latest(limit: initialWindowSize)
    )
    let initialTimeline = try #require(initialWindow.entries)
    let snapshot = HarnessMonitorSessionWindowSnapshot(
      summary: summary,
      detail: makeSessionDetail(
        summary: summary,
        workerID: "worker-edge-scroll",
        workerName: "Timeline Edge Worker"
      ),
      timeline: initialTimeline,
      timelineWindow: initialWindow,
      source: .live
    )
    let request = try #require(
      SessionTimelineWindowNavigation(
        timeline: snapshot.timeline,
        timelineWindow: snapshot.timelineWindow,
        isLoading: false
      ).request(for: .older, limit: 10)
    )

    #expect(store.timeline.isEmpty)
    #expect(store.timelineWindow == nil)

    let updatedSnapshot = try #require(
      await store.loadSessionWindowTimeline(
        sessionID: summary.sessionId,
        snapshot: snapshot,
        request: request
      )
    )

    #expect(updatedSnapshot.timeline.count == initialWindowSize + 10)
    #expect(updatedSnapshot.timelineWindow?.windowStart == 0)
    #expect(updatedSnapshot.timelineWindow?.windowEnd == initialWindowSize + 10)
    #expect(updatedSnapshot.timelineWindow?.hasOlder == true)
    #expect(store.timeline.isEmpty)
    #expect(store.timelineWindow == nil)
  }

  @MainActor
  private func makeBottomEdgeRequestFixture() async -> BottomEdgeRequestFixture {
    let summary = makeSession(
      .init(
        sessionId: "sess-edge-scroll-request",
        context: "Timeline edge scroll lane",
        status: .active,
        leaderId: "leader-edge-scroll",
        observeId: "observe-edge-scroll",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-edge-scroll",
      workerName: "Timeline Edge Worker"
    )
    let fullTimeline = (0..<46).map { index in
      TimelineEntry(
        entryId: "timeline-edge-scroll-\(index)",
        recordedAt: String(format: "2026-04-14T04:%02d:00Z", 59 - index),
        kind: "task_checkpoint",
        sessionId: summary.sessionId,
        agentId: detail.agents[0].agentId,
        taskId: nil,
        summary: "Timeline edge scroll \(index)",
        payload: .object([:])
      )
    }
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: fullTimeline],
      detail: detail
    )
    let store = await makeBootstrappedStore(client: client)
    return BottomEdgeRequestFixture(
      summary: summary,
      fullTimeline: fullTimeline,
      client: client,
      store: store
    )
  }

  private struct BottomEdgeRequestFixture {
    let summary: SessionSummary
    let fullTimeline: [TimelineEntry]
    let client: RecordingHarnessClient
    let store: HarnessMonitorStore
  }
}
