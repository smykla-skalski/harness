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

  @Test("Lane chrome uses a distinct neutral surface fill")
  func laneChromeUsesDistinctNeutralSurfaceFill() throws {
    let laneChrome = try taskBoardSourceFile(named: "TaskBoardLaneChrome.swift")

    #expect(laneChrome.contains("private var laneSurfaceFill: Color"))
    #expect(
      laneChrome.contains(
        "Color(red: 0.075, green: 0.105, blue: 0.11)"
      )
    )
    #expect(laneChrome.contains("Color(red: 0.925, green: 0.945, blue: 0.955)"))
    #expect(laneChrome.contains("shape.fill(laneSurfaceFill)"))
    #expect(laneChrome.contains("AnyShapeStyle(laneSurfaceFill)"))
    #expect(!laneChrome.contains("AnyShapeStyle(.background.opacity"))
  }

  @Test("Expanded and collapsed lane titles use matching type size")
  func expandedAndCollapsedLaneTitlesUseMatchingTypeSize() throws {
    let laneColumn = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let laneChrome = try taskBoardSourceFile(named: "TaskBoardLaneChrome.swift")
    let titleFontSource = ".title3.weight(.semibold)"

    #expect(laneChrome.contains(titleFontSource))
    #expect(laneColumn.contains(titleFontSource))
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
