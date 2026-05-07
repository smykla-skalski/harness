import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionTimelineNavigationTests {
  @Test("Timeline table measurement uses synchronous mode only for preview launches")
  func timelineTableMeasurementUsesSynchronousModeOnlyForPreviewLaunches() {
    #expect(
      SessionTimelineTableMeasurementMode.resolve(
        environment: [HarnessMonitorLaunchMode.xcodePreviewEnvironmentKey: "1"]
      ) == .synchronous
    )
    #expect(
      SessionTimelineTableMeasurementMode.resolve(environment: [:]) == .incremental
    )
    #expect(
      SessionTimelineTableMeasurementMode.resolve(
        environment: [
          HarnessMonitorLaunchMode.environmentKey: HarnessMonitorLaunchMode.live.rawValue,
          HarnessMonitorLaunchMode.xcodePreviewEnvironmentKey: "1",
        ]
      ) == .incremental
    )
  }

  @Test("Provisional cached row heights still require real measurement")
  @MainActor
  func provisionalCachedRowHeightsStillRequireRealMeasurement() {
    let provisional = CachedRowHeight(width: 945, height: 120, isMeasured: false)
    let measured = CachedRowHeight(width: 945, height: 120, isMeasured: true)

    #expect(
      provisional.requiresMeasurement(
        for: 945,
        tolerance: SessionTimelineTableView.Coordinator.widthEqualityTolerance
      )
    )
    #expect(
      !measured.requiresMeasurement(
        for: 945,
        tolerance: SessionTimelineTableView.Coordinator.widthEqualityTolerance
      )
    )
    #expect(
      measured.requiresMeasurement(
        for: 920,
        tolerance: SessionTimelineTableView.Coordinator.widthEqualityTolerance
      )
    )
  }

  @Test("Persistent height cache restores only unchanged measured rows")
  @MainActor
  func persistentHeightCacheRestoresOnlyUnchangedMeasuredRows() {
    SessionTimelineTableHeightCacheStore.removeAllForTests()
    defer { SessionTimelineTableHeightCacheStore.removeAllForTests() }

    let identity = SessionTimelineContentIdentity(sessionID: "session-revisit")
    let unchangedRow = makeCustomTimelineRow(
      id: "timeline-entry-unchanged",
      title: "Stable row"
    )
    let originalRow = makeCustomTimelineRow(
      id: "timeline-entry-stable",
      title: "Expandable row"
    )
    let changedRow = makeCustomTimelineRow(
      id: "timeline-entry-stable",
      title: "Expandable row",
      detail: "Expanded detail that changes the row layout"
    )

    SessionTimelineTableHeightCacheStore.save(
      identity: identity,
      snapshot: SessionTimelineTableSnapshot(rows: [unchangedRow, originalRow]),
      heightsByID: [
        unchangedRow.id: CachedRowHeight(width: 945, height: 118, isMeasured: true),
        originalRow.id: CachedRowHeight(width: 945, height: 136, isMeasured: true),
      ],
      fontScale: 1
    )

    let restored = SessionTimelineTableHeightCacheStore.restore(
      identity: identity,
      snapshot: SessionTimelineTableSnapshot(rows: [unchangedRow, changedRow]),
      fontScale: 1
    )

    #expect(restored?.heightsByID[unchangedRow.id]?.height == 118)
    #expect(restored?.heightsByID[changedRow.id] == nil)
  }

  @Test("Persistent height cache is scoped to font scale")
  @MainActor
  func persistentHeightCacheIsScopedToFontScale() {
    SessionTimelineTableHeightCacheStore.removeAllForTests()
    defer { SessionTimelineTableHeightCacheStore.removeAllForTests() }

    let identity = SessionTimelineContentIdentity(sessionID: "session-revisit")
    let row = makeCustomTimelineRow(id: "timeline-entry-stable", title: "Stable row")
    let otherRow = makeCustomTimelineRow(id: "timeline-entry-other", title: "Other stable row")
    let snapshot = SessionTimelineTableSnapshot(rows: [row, otherRow])

    SessionTimelineTableHeightCacheStore.save(
      identity: identity,
      snapshot: snapshot,
      heightsByID: [
        row.id: CachedRowHeight(width: 945, height: 118, isMeasured: true),
        otherRow.id: CachedRowHeight(width: 945, height: 122, isMeasured: true),
      ],
      fontScale: 1
    )

    let restored = SessionTimelineTableHeightCacheStore.restore(
      identity: identity,
      snapshot: snapshot,
      fontScale: 1.2
    )

    #expect(restored == nil)

    SessionTimelineTableHeightCacheStore.save(
      identity: identity,
      snapshot: snapshot,
      heightsByID: [
        row.id: CachedRowHeight(width: 945, height: 142, isMeasured: true)
      ],
      fontScale: 1.2
    )

    let restoredAtNewScale = SessionTimelineTableHeightCacheStore.restore(
      identity: identity,
      snapshot: snapshot,
      fontScale: 1.2
    )

    #expect(restoredAtNewScale?.heightsByID[row.id]?.height == 142)
    #expect(restoredAtNewScale?.heightsByID[otherRow.id] == nil)
  }

  @Test("Incremental measurement limits work to visible rows and prefetch")
  func incrementalMeasurementLimitsWorkToVisibleRowsAndPrefetch() {
    let indexes = SessionTimelineTableView.Coordinator.orderedMeasurementIndexes(
      rowCount: 40,
      visibleRange: 10..<14,
      mode: .incremental
    )

    #expect(indexes == Array(10..<18) + Array(6..<10))
  }

  @Test("Synchronous measurement still covers every row")
  func synchronousMeasurementStillCoversEveryRow() {
    let indexes = SessionTimelineTableView.Coordinator.orderedMeasurementIndexes(
      rowCount: 12,
      visibleRange: 3..<6,
      mode: .synchronous
    )

    #expect(indexes == Array(0..<12))
  }

  @Test("Viewport publish schedules measurement for visible unmeasured rows")
  @MainActor
  func viewportPublishSchedulesMeasurementForVisibleUnmeasuredRows() {
    let viewport = SessionTimelineViewportModel()
    let coordinator = SessionTimelineTableView.Coordinator(
      viewport: viewport,
      scrollBoundaryChanged: { _, _ in }
    )
    defer { coordinator.cancelMeasurement(reason: "test") }

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 945, height: 320))
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

    let initialRows = makeTimelineRows(count: 8)
    coordinator.update(
      rows: initialRows,
      actionHandler: NullDecisionActionHandler(),
      onSignalTap: nil,
      scrollCommand: nil,
      request: .init(
        scrollView: scrollView,
        columnWidth: 945,
        fontScale: 1
      )
    )
    coordinator.cancelMeasurement(reason: "test")
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)

    coordinator.rowHeightCache = [
      initialRows[0].id: CachedRowHeight(
        width: 945,
        height: SessionTimelineTableMetrics.estimatedHeight(for: initialRows[0]),
        isMeasured: false
      )
    ]

    coordinator.publishViewportState()

    #expect(coordinator.measurementTask != nil)
  }

  @Test("Minor width jitter preserves measured visible row heights")
  @MainActor
  func minorWidthJitterPreservesMeasuredVisibleRowHeights() {
    let viewport = SessionTimelineViewportModel()
    let coordinator = SessionTimelineTableView.Coordinator(
      viewport: viewport,
      scrollBoundaryChanged: { _, _ in }
    )
    defer { coordinator.cancelMeasurement(reason: "test") }

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 945, height: 320))
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

    let rows = makeTimelineRows(count: 8)
    coordinator.update(
      rows: rows,
      actionHandler: NullDecisionActionHandler(),
      onSignalTap: nil,
      scrollCommand: nil,
      request: .init(
        scrollView: scrollView,
        columnWidth: 945,
        fontScale: 1
      )
    )
    coordinator.cancelMeasurement(reason: "test")
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    let preservedRow = rows[0]
    let measuredHeight = tableView.rect(ofRow: 0).height
    coordinator.rowHeightCache = [
      preservedRow.id: CachedRowHeight(
        width: 945,
        height: measuredHeight,
        isMeasured: true
      )
    ]

    coordinator.update(
      rows: rows,
      actionHandler: NullDecisionActionHandler(),
      onSignalTap: nil,
      scrollCommand: nil,
      request: .init(
        scrollView: scrollView,
        columnWidth: 945.25,
        fontScale: 1
      )
    )

    #expect(coordinator.rowHeightCache[preservedRow.id]?.isMeasured == true)
    #expect(coordinator.rowHeightCache[preservedRow.id]?.height == measuredHeight)
    #expect(coordinator.measurementTask == nil)
  }

  @Test("Prepended updates do not carry provisional visible heights forward")
  @MainActor
  func prependedUpdatesDoNotCarryProvisionalVisibleHeightsForward() {
    let viewport = SessionTimelineViewportModel()
    let coordinator = SessionTimelineTableView.Coordinator(
      viewport: viewport,
      scrollBoundaryChanged: { _, _ in }
    )
    defer { coordinator.cancelMeasurement(reason: "test") }

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 945, height: 320))
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

    let initialRows = makeTimelineRows(count: 8)
    coordinator.update(
      rows: initialRows,
      actionHandler: NullDecisionActionHandler(),
      onSignalTap: nil,
      scrollCommand: nil,
      request: .init(
        scrollView: scrollView,
        columnWidth: 945,
        fontScale: 1
      )
    )
    coordinator.cancelMeasurement(reason: "test")
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    let provisionalRow = initialRows[0]
    coordinator.rowHeightCache = [
      provisionalRow.id: CachedRowHeight(
        width: 945,
        height: SessionTimelineTableMetrics.estimatedHeight(for: provisionalRow),
        isMeasured: false
      )
    ]

    let newTopRow = SessionTimelineRow(
      node: SessionTimelineNode(
        identity: .entry("timeline-entry-jitter-newest"),
        kind: .event,
        timestamp: Date(timeIntervalSince1970: 1_900_000_100),
        rawTimestamp: nil,
        sourceLabel: "worker-pagination",
        title: "Newest timeline entry",
        detail: nil,
        eventTone: .info,
        decision: nil
      ),
      dayDividerLabel: nil,
      timestampLabel: "10:00:59",
      accessibilityTimestampLabel: "14 Apr 10:00:59",
      accessibilityLabel: "Newest timeline entry"
    )

    coordinator.update(
      rows: [newTopRow] + initialRows,
      actionHandler: NullDecisionActionHandler(),
      onSignalTap: nil,
      scrollCommand: nil,
      request: .init(
        scrollView: scrollView,
        columnWidth: 945,
        fontScale: 1
      )
    )

    #expect(coordinator.rowHeightCache[provisionalRow.id] == nil)
    #expect(coordinator.measurementTask != nil)
  }
}
