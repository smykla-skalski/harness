import Foundation
import HarnessMonitorKit
import SwiftUI
import SwiftUIIntrospect

func taskBoardLaneIsDropTargeted(
  for phase: DropSession.Phase,
  isCandidate: Bool
) -> Bool {
  guard isCandidate else { return false }
  return switch phase {
  case .entering, .active:
    true
  case .exiting, .ended, .dataTransferCompleted:
    false
  @unknown default:
    false
  }
}

struct TaskBoardLaneUnifiedColumn: View {
  let lane: TaskBoardInboxLane
  let apiItems: [TaskBoardItem]
  let inboxItems: [TaskBoardInboxItem]
  let decisions: [Decision]
  /// This lane's own slice only, so a data change in one lane does not
  /// invalidate every column's diffed properties.
  let apiCardPresentations: [String: TaskBoardCardPresentation]
  let inboxCardPresentations: [TaskBoardCardID: TaskBoardCardPresentation]
  let titleTypography: TaskBoardCardTitleTypography
  let isCollapsed: Bool
  let dragRuntime: TaskBoardCardDragRuntime
  let dropHighlightState: TaskBoardLaneDropHighlightState
  let nativeListCoordinator: TaskBoardNativeListCoordinator
  let cardGapModel: TaskBoardCardGapModel
  let selectionModel: TaskBoardCardSelectionModel
  let revealCoordinator: TaskBoardLaneRevealCoordinator
  let actions: TaskBoardOverviewActions
  let onDrop: ([TaskBoardCardDragPayload], Int) -> Bool
  /// A variable with a default remains in the memberwise initializer, which
  /// lets static renders seed the quick-add field.
  var quickAddDraftTitle = ""
  @Binding var collapseOverridesRawValue: String
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.isEnabled)
  private var isLaneEnabled
  @State private var hoverTracking = TaskBoardLaneHoverTracking()
  @State private var hoveredCardID: TaskBoardLaneCardHoverID?
  private let perfScrollHookEnabled = HarnessMonitorPerfTaskBoardLaneScrollBus.isActiveAtLaunch

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var cardGapState: TaskBoardLaneCardGapState {
    cardGapModel.state(for: lane)
  }
  private var cardHoverCoordinateSpace: String {
    "task-board-lane-card-hover-\(lane.rawValue)"
  }

  private var totalCount: Int {
    apiItems.count + inboxItems.count + decisions.count
  }

  private var isEmpty: Bool {
    apiItems.isEmpty && inboxItems.isEmpty && decisions.isEmpty
  }

  private var orderedCardIDs: [TaskBoardCardID] {
    apiItems.map { .api($0.id) }
      + inboxItems.map {
        .inbox(sessionID: $0.session.sessionId, taskID: $0.task.taskId)
      }
  }

  private var actionableRevealRequest: TaskBoardLaneRevealRequest? {
    revealCoordinator.actionableRequest(
      in: lane,
      orderedCardIDs: orderedCardIDs
    )
  }

  var body: some View {
    laneContent
      .taskBoardLaneColumnChrome(
        lane: lane,
        isCollapsed: isCollapsed
      )
      .overlay {
        TaskBoardLaneDropHighlight(
          lane: lane,
          state: dropHighlightState
        )
      }
      .coordinateSpace(.named(cardHoverCoordinateSpace))
      .contentShape(.rect)
      .onDropSessionUpdated(handleLaneDropSession)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("harness.task-board.column.\(lane.rawValue)")
      .overlay {
        AccessibilityTextMarker(
          identifier: "harness.task-board.column.\(lane.rawValue).order",
          text: apiItems.map(\.id).joined(separator: ",")
        )
      }
      .onChange(of: apiItems.map(\.id), initial: true) { _, ids in
        traceTaskBoardCardDrag(
          "rendered-order lane=\(lane.rawValue) ids=\(ids.joined(separator: ","))"
        )
      }
      .onAppear {
        traceTaskBoardCardDrag(
          "lane-state lane=\(lane.rawValue) enabled=\(isLaneEnabled) "
            + "collapsed=\(isCollapsed) api=\(apiItems.count)"
        )
      }
  }

  @ViewBuilder private var laneContent: some View {
    if isCollapsed {
      collapsedLane
    } else {
      expandedLaneContent
    }
  }

  @ViewBuilder private var collapsedLane: some View {
    let content = TaskBoardCollapsedLane(
      lane: lane,
      count: totalCount,
      collapseOverridesRawValue: $collapseOverridesRawValue
    )
    if lane == .umbrella {
      content
    } else {
      content.taskBoardLaneFallbackDropDestination(
        acceptsDrop: { dragRuntime.accepts(lane) },
        insertionOffset: apiItems.count,
        action: onDrop
      )
    }
  }

  private var expandedLaneContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      TaskBoardLaneHeader(
        lane: lane,
        count: totalCount,
        collapseOverridesRawValue: $collapseOverridesRawValue
      )

      Group {
        // The source and every candidate need a mounted List during the drag.
        // Lifting a lane's only card must not detach its hit-test anchor.
        if isEmpty && !cardGapState.keepsListVisible {
          emptyLane
        } else {
          laneScrollSurface
        }
      }
      .taskBoardLaneBodyChrome(lane: lane)

      // Keep quick add pinned below the cards instead of letting it scroll away.
      if showsQuickAdd {
        TaskBoardLaneQuickAddRow(
          lane: lane,
          selectionModel: selectionModel,
          actions: actions,
          draftTitle: quickAddDraftTitle
        )
      }
    }
  }

  @ViewBuilder private var emptyLane: some View {
    let content = TaskBoardEmptyLane(lane: lane)
      .padding(.horizontal, metrics.laneInnerPadding)
      .padding(.top, metrics.laneHeaderBodyTopPadding)
      .padding(.bottom, metrics.laneInnerPadding)
    if lane == .umbrella {
      content
    } else {
      content.taskBoardLaneFallbackDropDestination(
        acceptsDrop: { dragRuntime.accepts(lane) },
        insertionOffset: 0,
        action: onDrop
      )
    }
  }

  private var showsQuickAdd: Bool {
    actions.canCreateItem && lane.acceptsQuickAddedTask
  }

  @ViewBuilder private var laneScrollSurface: some View {
    let surface =
      laneListDropSurface
      .task(id: actionableRevealRequest) {
        guard let request = actionableRevealRequest else { return }
        await revealCard(request)
      }
    if perfScrollHookEnabled {
      surface
        .onReceive(
          NotificationCenter.default.publisher(
            for: HarnessMonitorPerfTaskBoardLaneScrollBus.scrollToBottom
          )
        ) { note in
          handlePerfLaneScroll(note: note, edge: "bottom")
        }
        .onReceive(
          NotificationCenter.default.publisher(
            for: HarnessMonitorPerfTaskBoardLaneScrollBus.scrollToTop
          )
        ) { note in
          handlePerfLaneScroll(note: note, edge: "top")
        }
    } else {
      surface
    }
  }

  @ViewBuilder private var laneListDropSurface: some View {
    if lane != .umbrella {
      // The row destination does not cover the empty space below the last card.
      // The lane fallback uses the custom gap's exact offset there.
      styledLaneList.taskBoardLaneFallbackDropDestination(
        acceptsDrop: { dragRuntime.accepts(lane) },
        insertionOffset: cardGapState.insertionOffset ?? apiItems.count,
        action: onDrop
      )
    } else {
      styledLaneList
    }
  }

  @ViewBuilder private var styledLaneList: some View {
    if lane == .umbrella {
      styleLaneList(
        List {
          listRowsContent
        }
      )
    } else {
      styleLaneList(
        List {
          droppableListRowsContent
        }
      )
    }
  }

  private func styleLaneList<Content: View>(_ content: Content) -> some View {
    content
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .environment(\.defaultMinListRowHeight, 1)
      .contentMargins(
        .top,
        max(0, metrics.laneHeaderBodyTopPadding - metrics.laneSpacing / 2),
        for: .scrollContent
      )
      .contentMargins(
        .bottom,
        max(0, metrics.laneInnerPadding - metrics.laneSpacing / 2),
        for: .scrollContent
      )
      .scrollBounceBehavior(.basedOnSize)
      .introspect(.list, on: .macOS(.v26)) { tableView in
        nativeListCoordinator.register(tableView, lane: lane)
      }
      .dropConfiguration { _ in
        // Always resolve an accepting lane as a move. A copy leaves the source
        // in place and makes AppKit fly the preview home.
        dragRuntime.accepts(lane)
          ? DropConfiguration(operation: .move)
          : DropConfiguration(operation: .forbidden)
      }
      .onContinuousHover(coordinateSpace: .named(cardHoverCoordinateSpace)) { phase in
        guard !dragRuntime.isActive else { return }
        updateHoveredCard(phase: phase)
      }
  }

  private func handleLaneDropSession(_ session: DropSession) {
    // The pointer-polled custom gap owns insertion. SwiftUI's drop-session
    // callback only drives the lane highlight.
    TaskBoardCardDragDiagnostics.recordDropSession(session, lane: lane.rawValue)
    let targeted = taskBoardLaneIsDropTargeted(
      for: session.phase,
      isCandidate: dragRuntime.accepts(lane)
    )
    dragRuntime.setTargeted(targeted, lane: lane)
  }

  var laneListRows: [TaskBoardLaneListRow] {
    decisions.map(TaskBoardLaneListRow.decision)
      + apiItems.map(TaskBoardLaneListRow.api)
      + inboxItems.map(TaskBoardLaneListRow.inbox)
  }

  /// Live-reorders one stable card ID so List sees a move, never a
  /// remove-plus-insert that can cancel the native drag session.
  private var displayAPIItems: [TaskBoardItem] {
    guard
      cardGapState.isActive,
      case .api(let draggedItemID)? = cardGapState.draggedCardID
    else {
      return apiItems
    }
    var items = apiItems
    items.removeAll { $0.id == draggedItemID }
    if let index = cardGapState.displayIndex, let dragged = cardGapState.draggedItem {
      items.insert(dragged, at: min(max(index, 0), items.count))
    }
    return items
  }

  private var displayLaneListRows: [TaskBoardLaneListRow] {
    decisions.map(TaskBoardLaneListRow.decision)
      + displayAPIItems.map(TaskBoardLaneListRow.api)
      + inboxItems.map(TaskBoardLaneListRow.inbox)
  }

  private var listRowsContent: some DynamicViewContent {
    ForEach(displayLaneListRows) { row in
      taskBoardListRow(row)
    }
  }

  private var droppableListRowsContent: some DynamicViewContent {
    listRowsContent
      .dropDestination(for: TaskBoardCardDragPayload.self) { payloads, rowOffset in
        // A single-card exact move lands where the placeholder showed.
        // Multi-card and status drags fall back to the List's native row.
        let insertionOffset = cardGapState.insertionOffset
          ?? laneListRows.prefix(rowOffset).count(where: \.isAPI)
        traceTaskBoardCardDrag(
          "indexed-destination lane=\(lane.rawValue) "
            + "offset=\(insertionOffset) row-offset=\(rowOffset) "
            + "payloads=\(payloads.count)"
        )
        _ = onDrop(payloads, insertionOffset)
      }
  }

  // Every row keeps one stable root. A builder that swaps row shapes reaches
  // SwiftUI's HeterogeneousViewIDs path and crashes the List bridge with index -2.
  private func taskBoardListRow(_ row: TaskBoardLaneListRow) -> some View {
    styleListRow(
      ZStack {
        if cardGapState.isActive, let dragged = cardGapState.draggedCardID, row.cardID == dragged {
          taskBoardGapPlaceholder(cardID: dragged, showsMarker: cardGapState.showsMarker)
        } else {
          taskBoardListRowContent(row)
        }
      }
    )
  }

  // The placeholder keeps its draggable identity so the drag container never
  // observes a remove-without-insert. Only the exact target draws the slot.
  private func taskBoardGapPlaceholder(
    cardID: TaskBoardCardID,
    showsMarker: Bool
  ) -> some View {
    Color.clear
      // `styleListRow` adds the measured row's vertical insets back.
      .frame(height: max(1, cardGapState.gapHeight - metrics.laneSpacing))
      .overlay {
        if showsMarker {
          RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
            .fill(HarnessMonitorTheme.accent.opacity(0.12))
            .overlay {
              RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
                .strokeBorder(
                  HarnessMonitorTheme.accent.opacity(0.45),
                  style: StrokeStyle(lineWidth: 1.5, dash: [5])
                )
            }
        }
      }
      .draggable(containerItemID: cardID)
  }

  @ViewBuilder
  private func taskBoardListRowContent(_ row: TaskBoardLaneListRow) -> some View {
    switch row {
    case .decision(let decision):
      taskBoardDecisionRow(decision)
    case .api(let item):
      taskBoardAPIRow(item)
    case .inbox(let item):
      taskBoardInboxRow(item)
    }
  }

  private func taskBoardAPIRow(_ item: TaskBoardItem) -> some View {
    let cardID = TaskBoardCardID.api(item.id)
    let hoverID = TaskBoardLaneCardHoverID.api(item.id)
    return TaskBoardItemRow(
      item: item,
      titleTypography: titleTypography,
      isHovered: hoveredCardID == hoverID,
      isSelected: selectionModel.selectedIDs.contains(cardID),
      selectionModel: selectionModel,
      actions: actions,
      cardPresentation: apiCardPresentations[item.id]
    )
    .taskBoardCardFrame(
      id: hoverID,
      in: cardHoverCoordinateSpace,
      tracking: hoverTracking,
      isHovered: hoveredCardID == hoverID,
      onChange: resolveHoveredCard
    )
    .background {
      TaskBoardCardContextMenu(cardID: cardID)
    }
  }

  private func taskBoardInboxRow(_ item: TaskBoardInboxItem) -> some View {
    let cardID = TaskBoardCardID.inbox(
      sessionID: item.session.sessionId,
      taskID: item.task.taskId
    )
    let hoverID = TaskBoardLaneCardHoverID.inbox(
      sessionID: item.session.sessionId,
      taskID: item.task.taskId
    )
    return TaskBoardInboxItemRow(
      item: item,
      titleTypography: titleTypography,
      isHovered: hoveredCardID == hoverID,
      isSelected: selectionModel.selectedIDs.contains(cardID),
      selectionModel: selectionModel,
      actions: actions,
      cardPresentation: inboxCardPresentations[cardID]
    )
    .taskBoardCardFrame(
      id: hoverID,
      in: cardHoverCoordinateSpace,
      tracking: hoverTracking,
      isHovered: hoveredCardID == hoverID,
      onChange: resolveHoveredCard
    )
    .background {
      TaskBoardCardContextMenu(cardID: cardID)
    }
  }

  private func taskBoardDecisionRow(_ decision: Decision) -> some View {
    let hoverID = TaskBoardLaneCardHoverID.decision(decision.id)
    return TaskBoardDecisionRow(
      decision: decision,
      fontScale: fontScale,
      isHovered: hoveredCardID == hoverID,
      actions: actions
    )
    .taskBoardCardFrame(
      id: hoverID,
      in: cardHoverCoordinateSpace,
      tracking: hoverTracking,
      isHovered: hoveredCardID == hoverID,
      onChange: resolveHoveredCard
    )
  }

  private func styleListRow<Content: View>(_ content: Content) -> some View {
    content
      .listRowInsets(
        EdgeInsets(
          top: metrics.laneSpacing / 2,
          leading: metrics.listRowHorizontalInset,
          bottom: metrics.laneSpacing / 2,
          trailing: metrics.listRowHorizontalInset
        )
      )
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
  }

  private func updateHoveredCard(phase: HoverPhase) {
    TaskBoardCardDragDiagnostics.recordHoverPhase(lane: lane.rawValue)
    switch phase {
    case .active(let location):
      hoverTracking.location = location
      resolveHoveredCard()
    case .ended:
      hoverTracking.location = nil
      updateHoveredCard(id: nil)
    }
  }

  /// Re-picks from the last pointer location when scrolling moves content
  /// underneath a stationary pointer.
  private func resolveHoveredCard() {
    TaskBoardCardDragDiagnostics.recordHoverResolution(lane: lane.rawValue)
    guard !dragRuntime.isActive else { return }
    guard let location = hoverTracking.location else {
      updateHoveredCard(id: nil)
      return
    }
    updateHoveredCard(id: hoverTracking.cardID(at: location))
  }

  private func updateHoveredCard(id: TaskBoardLaneCardHoverID?) {
    guard hoveredCardID != id else {
      return
    }
    TaskBoardCardDragDiagnostics.recordHoverMutation(lane: lane.rawValue)
    hoveredCardID = id
  }
}
