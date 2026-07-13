import Foundation
import Testing

@Suite("Task board card presentation contracts")
struct TaskBoardCardPresentationContractTests {
  @Test("Repository leads the footer before card badges")
  func repositoryLeadsFooterBeforeCardBadges() throws {
    let source = try taskBoardSource("TaskBoardLaneSupport.swift")
    let repository = try #require(source.range(of: "Text(repository)"))
    let badges = try #require(source.range(of: "HarnessMonitorWrapLayout("))

    #expect(repository.lowerBound < badges.lowerBound)
    #expect(source.contains(".multilineTextAlignment(.leading)"))
  }

  @Test("Card update labels share one board-owned minute clock")
  func cardUpdateLabelsShareBoardClock() throws {
    let overview = try taskBoardSource("TaskBoardOverviewView.swift")
    let rows = try taskBoardSource("TaskBoardLaneViews.swift")
    let support = try taskBoardSource("TaskBoardLaneSupport.swift")

    #expect(overview.contains("@State private var relativeTimeClock"))
    #expect(overview.contains(".environment(relativeTimeClock)"))
    #expect(overview.contains("await relativeTimeClock.run()"))
    #expect(rows.contains("updatedAt: item.updatedAt"))
    #expect(rows.contains("updatedAt: item.task.updatedAt"))
    #expect(support.contains("@Environment(TaskBoardRelativeTimeClock.self)"))
    #expect(support.contains("Task.sleep(for: .seconds(60))"))
    #expect(!rows.contains("TimelineView"))
    #expect(!rows.contains("Timer.publish"))
  }

  @Test("Board resolves scaled task-title fonts once and passes them through lanes")
  func boardPassesScaledTaskTitleFontsThroughLanes() throws {
    let overviewSource = try taskBoardSource("TaskBoardOverviewView+Board.swift")
    let laneSource = try taskBoardSource("TaskBoardLaneUnifiedColumn.swift")
    let rowSource = try taskBoardSource("TaskBoardLaneViews.swift")
    let textSource = try taskBoardSource("TaskBoardInlineCodeText.swift")

    #expect(
      overviewSource.contains(
        "let titleTypography = TaskBoardCardTitleTypography(fontScale: fontScale)"
      )
    )
    #expect(overviewSource.contains("taskBoardLaneColumns(titleTypography: titleTypography)"))
    #expect(laneSource.components(separatedBy: "titleTypography: titleTypography").count == 3)
    #expect(laneSource.contains("let titleTypography: TaskBoardCardTitleTypography"))
    #expect(rowSource.contains("let titleTypography: TaskBoardCardTitleTypography"))
    #expect(!textSource.contains("@Environment(\\.fontScale)"))
    #expect(textSource.contains("codeFont: codeFont"))
    #expect(textSource.contains(".font(font)"))
  }

  @Test("Cards omit background glyphs while retaining the reusable modifier")
  func cardsOmitBackgroundGlyphsWhileRetainingModifier() throws {
    let laneSource = try taskBoardSource("TaskBoardLaneViews.swift")
    let decisionSource = try taskBoardSource("TaskBoardNeedsYouLaneViews.swift")
    let glyphSource = try taskBoardSource("TaskBoardCardBackgroundGlyph.swift")

    #expect(!laneSource.contains(".taskBoardCardBackgroundGlyph("))
    #expect(!decisionSource.contains(".taskBoardCardBackgroundGlyph("))
    #expect(glyphSource.contains("func taskBoardCardBackgroundGlyph("))
    #expect(glyphSource.contains(".rotationEffect(glyphRotation)"))
  }

  private func taskBoardSource(_ fileName: String) throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot =
      testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL =
      appRoot
      .appendingPathComponent("Sources/HarnessMonitorUIPreviewable/Views/TaskBoard")
      .appendingPathComponent(fileName)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
