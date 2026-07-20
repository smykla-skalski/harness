import Foundation
import Testing

extension TaskBoardOverviewBehaviorTests {
  @Test("Task card hover feedback stays lane scoped")
  func taskCardHoverFeedbackStaysLaneScoped() throws {
    let support = try taskBoardSourceFile(named: "TaskBoardLaneSupport.swift")
    let laneColumn = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let laneRows = try taskBoardSourceFile(named: "TaskBoardLaneViews.swift")
    let needsYouRows = try taskBoardSourceFile(named: "TaskBoardNeedsYouLaneViews.swift")

    #expect(support.contains("extraHoverHint: isHovered"))
    #expect(support.contains("respondsToHover: false"))
    #expect(
      laneColumn.contains(
        ".onContinuousHover(coordinateSpace: .named(cardHoverCoordinateSpace))"
      )
    )
    #expect(laneColumn.contains("updateHoveredCard(id: nil)"))
    #expect(!support.contains(".onHover {"))
    #expect(!laneRows.contains(".onHover {"))
    #expect(!needsYouRows.contains(".onHover {"))
  }

  @Test("Lane card frames report per card, not through a bound preference")
  func laneCardFramesAvoidBoundPreferenceAggregation() throws {
    let support = try taskBoardSourceFile(named: "TaskBoardLaneSupport.swift")
    let laneColumn = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")

    // One PreferenceKey reduced across every card in the LazyVStack updated
    // several times per frame as lazy children measured in, which SwiftUI
    // faults as "bound preference ... tried to update multiple times per frame".
    // Per-card onGeometryChange has no cross-sibling reduce.
    #expect(!support.contains("PreferenceKey"))
    #expect(!laneColumn.contains(".onPreferenceChange("))
    #expect(support.contains("onGeometryChange(for: CGRect.self)"))
    #expect(support.contains("tracking.setFrame(frame, for: id)"))
  }

  @Test("Expanded lane scroll content owns its padding")
  func expandedLaneScrollContentOwnsItsPadding() throws {
    let laneColumn = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let laneChrome = try taskBoardSourceFile(named: "TaskBoardLaneChrome.swift")
    let laneScrollViewSource =
      "ScrollView(.vertical, showsIndicators: true) {\n        laneScrollContent\n      }"

    #expect(
      laneColumn.contains(
        """
        VStack(alignment: .leading, spacing: 0) {
              TaskBoardLaneHeader(
        """
      )
    )
    #expect(laneColumn.contains("private var laneScrollContent: some View"))
    #expect(laneColumn.components(separatedBy: laneScrollViewSource).count == 3)
    #expect(
      laneColumn.contains(
        """
        laneRows
              .padding(.horizontal, metrics.laneInnerPadding)
              .padding(.top, metrics.laneHeaderBodyTopPadding)
              .padding(.bottom, metrics.laneInnerPadding)
              .frame(maxWidth: .infinity, alignment: .top)
        """
      )
    )
    #expect(!laneColumn.contains(".contentMargins("))
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
    let support = try taskBoardSourceFile(named: "TaskBoardLaneSupport.swift")

    #expect(support.contains("private var cardSurfaceFill: Color"))
    #expect(support.contains("Color(red: 0.205, green: 0.24, blue: 0.25)"))
    #expect(support.contains("Color(red: 0.99, green: 0.995, blue: 1)"))
    #expect(support.contains(".fill(cardSurfaceFill)"))
    #expect(!support.contains(".background.opacity(reduceTransparency ? 0.68 : 0.56)"))
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
    let laneColumn = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let interaction = try taskBoardSourceFile(
      named: "TaskBoardOverviewView+CardInteraction.swift"
    )

    #expect(board.contains("dropCandidateLanesValue.contains(lane)"))
    #expect(interaction.contains("cardDropPlan(cardIDs, to: $0) != nil"))
    #expect(laneColumn.contains("isDropEnabled && isDropCandidate"))
    #expect(laneColumn.contains("DropConfiguration(operation: operation)"))
    #expect(laneColumn.contains("? .move : .forbidden"))
    #expect(laneColumn.contains("TaskBoardCardDropPlan.resolve(payloads, to: lane)"))
    #expect(!laneColumn.contains("_: CGPoint"))
    #expect(interaction.contains("TaskBoardCardDropPlan.resolve(cardDragPayloads(cardIDs)"))
  }

  @Test("Lifted cards highlight only lanes with valid drop plans")
  func liftedCardsHighlightOnlyValidDropDestinations() throws {
    let board = try taskBoardSourceFile(named: "TaskBoardOverviewView+Board.swift")
    let interaction = try taskBoardSourceFile(
      named: "TaskBoardOverviewView+CardInteraction.swift"
    )
    let laneColumn = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let laneChrome = try taskBoardSourceFile(named: "TaskBoardLaneChrome.swift")

    #expect(board.contains("dropCandidateLanesValue.contains(lane)"))
    #expect(interaction.contains("case .initial, .active:"))
    #expect(interaction.contains("updateDraggedCardIDs(draggedIDs)"))
    #expect(interaction.contains("case .ended, .dataTransferCompleted:"))
    #expect(interaction.contains("dropCandidateLanesValue ="))
    #expect(laneColumn.contains("isDropCandidate: isDropCandidate"))
    #expect(laneChrome.contains("if isDropCandidate"))
    #expect(laneChrome.contains("value: isDropCandidate"))
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
