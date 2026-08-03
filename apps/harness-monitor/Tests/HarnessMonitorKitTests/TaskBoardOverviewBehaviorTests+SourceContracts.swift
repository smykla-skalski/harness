import Foundation
import Testing

extension TaskBoardOverviewBehaviorTests {
  @Test("Task card hover feedback stays lane scoped")
  func taskCardHoverFeedbackStaysLaneScoped() throws {
    let cardChrome = try taskBoardSourceFile(named: "TaskBoardCardChrome.swift")
    let laneColumn = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let laneRowSupport = try taskBoardSourceFile(
      named: "TaskBoardLaneUnifiedColumn+Rows.swift"
    )
    let laneRows = try taskBoardSourceFile(named: "TaskBoardLaneViews.swift")
    let needsYouRows = try taskBoardSourceFile(named: "TaskBoardNeedsYouLaneViews.swift")

    #expect(cardChrome.contains("extraHoverHint: isHovered"))
    #expect(cardChrome.contains("respondsToHover: false"))
    #expect(
      laneColumn.contains(
        ".onContinuousHover(coordinateSpace: .named(cardHoverCoordinateSpace))"
      )
    )
    #expect(laneRowSupport.contains("updateHoveredCard(id: nil)"))
    #expect(!cardChrome.contains(".onHover {"))
    #expect(!laneRows.contains(".onHover {"))
    #expect(!needsYouRows.contains(".onHover {"))
  }

  @Test("Lane card frames report per card, not through a bound preference")
  func laneCardFramesAvoidBoundPreferenceAggregation() throws {
    let cardChrome = try taskBoardSourceFile(named: "TaskBoardCardChrome.swift")
    let hoverTracking = try taskBoardSourceFile(named: "TaskBoardLaneHoverTracking.swift")
    let laneColumn = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")

    // The old aggregation reduced one PreferenceKey across every card in the
    // lane; it updated several times per frame as children measured in, which
    // SwiftUI faults as "bound preference ... tried to update multiple times per
    // frame". Target that specific pattern - the key and its frame-pair struct -
    // not the whole PreferenceKey API, which unrelated future code in these files
    // may legitimately use. The positive checks are the real guard: the
    // card-frame modifier must keep reporting per card.
    #expect(!cardChrome.contains("TaskBoardLaneCardFramePreferenceKey"))
    #expect(!hoverTracking.contains("TaskBoardLaneCardFramePreferenceKey"))
    #expect(!cardChrome.contains("TaskBoardLaneCardFrame("))
    #expect(!laneColumn.contains("TaskBoardLaneCardFramePreferenceKey"))
    #expect(cardChrome.contains("onGeometryChange(for: CGRect.self)"))
    #expect(cardChrome.contains("tracking.setFrame(frame, for: id)"))
  }

  @Test("Expanded lane List owns custom insertion and card spacing")
  func expandedLaneListOwnsCustomInsertionAndCardSpacing() throws {
    let laneColumn = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let laneReveal = try taskBoardSourceFile(
      named: "TaskBoardLaneUnifiedColumn+Reveal.swift"
    )
    let laneRows = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn+Rows.swift")
    let listTuner = try taskBoardSourceFile(named: "TaskBoardNativeListTuner.swift")
    let laneChrome = try taskBoardSourceFile(named: "TaskBoardLaneChrome.swift")

    #expect(
      laneColumn.contains(
        """
        VStack(alignment: .leading, spacing: 0) {
              TaskBoardLaneHeader(
        """
      )
    )
    #expect(laneColumn.contains("List {"))
    #expect(laneColumn.contains("private var droppableListRowsContent: some DynamicViewContent"))
    #expect(laneColumn.contains("ForEach(displayLaneListRows)"))
    #expect(
      laneColumn.contains(
        ".dropDestination(for: TaskBoardCardDragPayload.self) { payloads, rowOffset in"
      )
    )
    #expect(laneReveal.contains("await nativeListCoordinator.reveal(row:"))
    #expect(laneRows.contains(".listRowInsets("))
    #expect(laneRows.contains("leading: metrics.listRowHorizontalInset"))
    #expect(laneRows.contains("trailing: metrics.listRowHorizontalInset"))
    #expect(laneRows.contains(".listRowSeparator(.hidden)"))
    #expect(laneRows.contains(".listRowBackground(Color.clear)"))
    #expect(laneColumn.contains(".introspect(.list, on: .macOS(.v26))"))
    #expect(listTuner.contains("draggingDestinationFeedbackStyle = .none"))
    #expect(laneColumn.contains("var cardGapState: TaskBoardLaneCardGapState"))
    #expect(laneColumn.contains("cardGapState.displayIndex"))
    #expect(laneRows.contains("cardGapState.showsMarker"))
    #expect(laneRows.contains("StrokeStyle(lineWidth: 1.5, dash: [5])"))
    #expect(laneRows.contains("HarnessMonitorTheme.accent.opacity(0.12)"))
    #expect(!laneColumn.contains("cardGapModel.target"))
    #expect(listTuner.contains("setGapTarget(nil, reason: \"before-model-mutation\")"))
    #expect(listTuner.contains("selectionHighlightStyle = .none"))
    #expect(listTuner.contains("focusRingType = .none"))
    #expect(listTuner.contains("tableView.scrollRowToVisible(row)"))
    #expect(!listTuner.contains(".delegate ="))
    #expect(!listTuner.contains(".dataSource ="))
    #expect(
      laneChrome.contains(
        ".padding(.horizontal, metrics.laneInnerPadding)"
      )
    )
    #expect(
      laneColumn.contains(
        """
        TaskBoardEmptyLane(lane: lane)
              .padding(.horizontal, metrics.laneInnerPadding)
              .padding(.top, metrics.laneHeaderBodyTopPadding)
              .padding(.bottom, metrics.laneInnerPadding)
        """
      )
    )
    #expect(!laneColumn.contains("LazyVStack"))
    #expect(!laneColumn.contains("insertionMarker("))
    #expect(!laneChrome.contains(".padding(.top, metrics.laneHeaderBodyTopPadding)"))
  }

  @Test("Lane chrome uses a distinct neutral surface fill")
  func laneChromeUsesDistinctNeutralSurfaceFill() throws {
    let laneChrome = try taskBoardSourceFile(named: "TaskBoardLaneChrome.swift")

    #expect(laneChrome.contains("private var laneSurfaceFill: Color"))
    #expect(
      laneChrome.contains(
        "Color(red: 0.155, green: 0.19, blue: 0.2)"
      )
    )
    #expect(laneChrome.contains("Color(red: 0.925, green: 0.945, blue: 0.955)"))
    #expect(laneChrome.contains("shape.fill(laneSurfaceFill)"))
    #expect(laneChrome.contains("AnyShapeStyle(laneSurfaceFill)"))
    #expect(!laneChrome.contains("AnyShapeStyle(.background.opacity"))
  }

  @Test("Task cards use a raised neutral surface fill")
  func taskCardsUseRaisedNeutralSurfaceFill() throws {
    let cardChrome = try taskBoardSourceFile(named: "TaskBoardCardChrome.swift")

    #expect(cardChrome.contains("private var cardSurfaceFill: Color"))
    #expect(cardChrome.contains("Color(red: 0.205, green: 0.24, blue: 0.25)"))
    #expect(cardChrome.contains("Color(red: 0.99, green: 0.995, blue: 1)"))
    #expect(cardChrome.contains(".fill(cardSurfaceFill)"))
    #expect(!cardChrome.contains(".background.opacity(reduceTransparency ? 0.68 : 0.56)"))
  }

  @Test("Expanded and collapsed lane titles use matching type size")
  func expandedAndCollapsedLaneTitlesUseMatchingTypeSize() throws {
    let collapsedLane = try taskBoardSourceFile(named: "TaskBoardCollapsedLane.swift")
    let laneChrome = try taskBoardSourceFile(named: "TaskBoardLaneChrome.swift")
    let titleFontSource = ".title3.weight(.semibold)"

    #expect(laneChrome.contains(titleFontSource))
    #expect(collapsedLane.contains(titleFontSource))
  }

  @Test("Lane drops derive from the precomputed drop-candidate set")
  func laneDropsUseModernSessionPlanForAcceptanceAndAction() throws {
    let board = try taskBoardSourceFile(named: "TaskBoardOverviewView+Board.swift")
    let boardDrop = try taskBoardSourceFile(named: "TaskBoardOverviewView+BoardDrop.swift")
    let laneColumn = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let listTuner = try taskBoardSourceFile(named: "TaskBoardNativeListTuner.swift")
    let fallback = try taskBoardSourceFile(
      named: "TaskBoardLaneFallbackDropDestination.swift"
    )
    let interaction = try taskBoardSourceFile(
      named: "TaskBoardOverviewView+CardInteraction.swift"
    )
    let dragRuntime = try taskBoardSourceFile(named: "TaskBoardCardDragRuntime.swift")

    #expect(board.contains("dragRuntime: cardDragRuntimeValue"))
    #expect(board.contains("dropHighlightState: cardDragRuntimeValue.highlightState(for: lane)"))
    #expect(interaction.contains("cardDropPlan(cardIDs, to: $0) != nil"))
    #expect(interaction.contains("cardDragRuntimeValue.begin("))
    #expect(dragRuntime.contains("candidateLanes.contains(lane)"))
    #expect(laneColumn.contains("private var listRowsContent: some DynamicViewContent"))
    #expect(laneColumn.contains("private var droppableListRowsContent: some DynamicViewContent"))
    #expect(laneColumn.contains("indexed-destination"))
    #expect(laneColumn.contains(".introspect(.list, on: .macOS(.v26))"))
    #expect(laneColumn.contains("nativeListCoordinator.register(tableView, lane: lane)"))
    #expect(listTuner.contains("draggingDestinationFeedbackStyle = .none"))
    #expect(listTuner.contains("setGapTarget(nil, reason: \"before-model-mutation\")"))
    #expect(fallback.contains(".dropDestination(for: TaskBoardCardDragPayload.self)"))
    #expect(fallback.contains("guard acceptsDrop()"))
    #expect(fallback.contains("_ = action(payloads, insertionOffset)"))
    #expect(boardDrop.contains("TaskBoardCardDropPlan.resolve(payloads, to: lane)"))
    #expect(boardDrop.contains("TaskBoardCardReorderPlan.dropDecision("))
    #expect(boardDrop.contains("currentPresentation.apiItems(in: lane)"))
    #expect(!laneColumn.contains("TaskBoardCardReorderInsertionGap"))
    #expect(!board.contains(".onDrop("))
    #expect(!boardDrop.contains("DropDelegate"))
    #expect(interaction.contains("TaskBoardCardDropPlan.resolve(cardDragPayloads(cardIDs)"))
  }

  @Test("Busy state keeps the active drag container stable")
  func busyStateKeepsActiveDragContainerStable() throws {
    let board = try taskBoardSourceFile(named: "TaskBoardOverviewView+Board.swift")
    let boardDrop = try taskBoardSourceFile(named: "TaskBoardOverviewView+BoardDrop.swift")
    let laneColumn = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let overview = try taskBoardSourceFile(named: "TaskBoardOverviewView.swift")
    let interaction = try taskBoardSourceFile(
      named: "TaskBoardOverviewView+CardInteraction.swift"
    )

    #expect(board.contains("cardDragPayloads(cardIDs)"))
    #expect(!board.contains("isActionInFlight ? [] : cardDragPayloads(cardIDs)"))
    #expect(board.contains(".dragContainerSelection(orderedSelectedCardIDs)"))
    #expect(board.contains(".dragConfiguration(.init(allowMove: true))"))
    #expect(board.contains("dragRuntime: cardDragRuntimeValue"))
    #expect(board.contains("nativeListCoordinator: nativeListCoordinatorValue"))
    #expect(!board.contains("ViewThatFits"))
    #expect(
      board.components(
        separatedBy: "taskBoardLaneStrip(titleTypography: titleTypography)"
      ).count == 2
    )
    #expect(!board.contains(".dropDestination("))
    #expect(laneColumn.contains(".dropDestination("))
    #expect(laneColumn.contains("droppableListRowsContent"))
    #expect(!laneColumn.contains("isEnabled: isActionInFlight"))
    #expect(boardDrop.contains("!isActionInFlight"))
    #expect(boardDrop.contains("transaction.disablesAnimations = true"))
    #expect(boardDrop.contains("withTransaction(transaction)"))
    #expect(boardDrop.contains("defer { clearTransientCardDragState() }"))
    #expect(boardDrop.contains("applyImmediateTaskBoardPositionProjection()"))
    #expect(
      overview.contains(
        "currentPresentation.replacingTaskBoardItemsForImmediatePosition("
      )
    )
    #expect(overview.contains("@Environment(\\.scenePhase)"))
    #expect(overview.contains(".onChange(of: scenePhase)"))
    #expect(overview.contains(".onChange(of: isCommandFocusActive)"))
    #expect(overview.contains(".onKeyPress(.escape"))
    #expect(overview.contains(".onDisappear"))
    #expect(interaction.contains("clearTransientCardDragState()"))
  }

  @Test("Lifted cards highlight only lanes with valid drop plans")
  func liftedCardsHighlightOnlyValidDropDestinations() throws {
    let board = try taskBoardSourceFile(named: "TaskBoardOverviewView+Board.swift")
    let interaction = try taskBoardSourceFile(
      named: "TaskBoardOverviewView+CardInteraction.swift"
    )
    let laneColumn = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let laneChrome = try taskBoardSourceFile(named: "TaskBoardLaneChrome.swift")
    let dragRuntime = try taskBoardSourceFile(named: "TaskBoardCardDragRuntime.swift")
    let dragDecisions = try taskBoardSourceFile(named: "TaskBoardCardDragDiagnostics.swift")

    #expect(board.contains("dropHighlightState: cardDragRuntimeValue.highlightState(for: lane)"))
    #expect(interaction.contains("switch taskBoardCardDragSessionDecision("))
    #expect(dragDecisions.contains("case .initial:"))
    #expect(dragDecisions.contains("case .active:"))
    #expect(interaction.contains("updateInitialCardDrag(session)"))
    #expect(interaction.contains("updateDraggedCardIDs(draggedIDs)"))
    #expect(dragDecisions.contains("case .ended(let operation):"))
    #expect(dragDecisions.contains("case .dataTransferCompleted:"))
    #expect(dragDecisions.contains("operation == .move || operation == .copy ? .ignore : .clear"))
    #expect(interaction.contains("cardDragRuntimeValue.begin("))
    #expect(dragRuntime.contains("final class TaskBoardLaneDropHighlightState"))
    #expect(dragRuntime.contains("highlightState(for: lane).setTargeted(true)"))
    #expect(laneColumn.contains("TaskBoardLaneDropHighlight("))
    #expect(laneChrome.contains("state.isTargeted"))
  }

  @Test("Only the collapsed rail keeps the bounded toggle highlight")
  func onlyCollapsedRailKeepsBoundedToggleHighlight() throws {
    let collapsedLane = try taskBoardSourceFile(named: "TaskBoardCollapsedLane.swift")
    let laneChrome = try taskBoardSourceFile(named: "TaskBoardLaneChrome.swift")
    let headerFade = try taskBoardSourceFile(named: "TaskBoardLaneHeaderFade.swift")

    #expect(collapsedLane.contains(".taskBoardLaneToggleFeedback(lane: lane"))
    #expect(laneChrome.contains(".taskBoardLaneHeaderFade(lane: lane"))
    #expect(!laneChrome.contains(".taskBoardLaneToggleFeedback(lane: lane"))
    // The fade replaces the outline rather than joining it; an outline would
    // put back the bounded shape that read as a card on top of the lane.
    #expect(!headerFade.contains("strokeBorder"))
    #expect(!headerFade.contains(".stroke("))
    // Direction and shape carry the effect. Falling weights alone would still
    // let the wash run bottom-up, or run square across the lane's top corners.
    #expect(headerFade.contains("startPoint: .top"))
    #expect(headerFade.contains("endPoint: .bottom"))
    #expect(headerFade.contains("TaskBoardLaneTopRoundedShape(cornerRadius: cornerRadius)"))
  }

  private func taskBoardSourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent("Views/TaskBoard")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
