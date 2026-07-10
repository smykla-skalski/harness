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

  @Test("Expanded lanes do not add extra header body spacing")
  func expandedLanesDoNotAddExtraHeaderBodySpacing() throws {
    let laneColumn = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let laneChrome = try taskBoardSourceFile(named: "TaskBoardLaneChrome.swift")

    #expect(
      laneColumn.contains(
        """
        VStack(alignment: .leading, spacing: 0) {
              TaskBoardLaneHeader(
        """
      )
    )
    #expect(laneChrome.contains(".padding(.top, metrics.laneHeaderBodyTopPadding)"))
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
