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
