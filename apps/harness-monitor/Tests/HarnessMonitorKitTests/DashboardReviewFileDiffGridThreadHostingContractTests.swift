import Foundation
import Testing

/// Source contract for hosting inline conversation cards inside the AppKit diff
/// canvas. The hosting/measurement path is AppKit + NSHostingView (not unit
/// testable without a window); the row<->Y math is covered by
/// ``DashboardReviewFileDiffThreadLayoutTests`` and the live behavior by the
/// Phase 8 launch verification. These assertions pin the wiring against drift.
@Suite("Dashboard review file diff grid thread hosting contracts")
struct DashboardReviewFileDiffGridThreadHostingContractTests {
  @Test("the diff canvas drives draw + hit-testing through the variable layout")
  func canvasUsesVariableLayout() throws {
    let grid = try source(named: "Views/Dashboard/DashboardReviewFileDiffGrid.swift")
    // Draw culling + row rects route through the layout, not flat row math.
    #expect(grid.contains("layout.visibleRowRange(in: dirtyRect)"))
    #expect(grid.contains("layout.rowRect(index, width: bounds.width)"))
    #expect(grid.contains("rebuildThreadLayout(contentWidth: width)"))
    #expect(grid.contains("layoutThreadCards(contentWidth: width)"))
    // New conversation inputs reach configure.
    #expect(grid.contains("conversationThreads: [DashboardReviewFileThread]"))
    #expect(grid.contains("conversationVisibility: ConversationVisibility"))

    let actions = try source(named: "Views/Dashboard/DashboardReviewFileDiffGrid+Actions.swift")
    #expect(actions.contains("layout.rowIndexHittingTextLine(atY: point.y)"))
  }

  @Test("hosting resolves visible threads, measures, and slides on height change")
  func hostingMeasuresAndReflows() throws {
    let hosting = try source(
      named: "Views/Dashboard/DashboardReviewFileDiffGrid+ThreadHosting.swift"
    )
    #expect(hosting.contains("NSHostingView<DashboardReviewInlineThreadCardStack>"))
    // Visibility filtering reuses the tested ConversationVisibility predicate.
    #expect(hosting.contains("conversationVisibility.shows(isResolved: $0.isResolved)"))
    #expect(hosting.contains("func measuredCardStackHeight("))
    #expect(hosting.contains("func handleCardHeight("))
    // Height-change reflow is threshold-gated against oscillation.
    #expect(hosting.contains("> 0.5"))
    #expect(hosting.contains("layout.cardRect("))
  }

  @Test("hosted card stack reports height and keys cards by thread id")
  func cardStackReportsHeightAndKeysByThread() throws {
    let stack = try source(named: "Views/Dashboard/DashboardReviewInlineThreadCardStack.swift")
    #expect(stack.contains("onGeometryChange(for: CGFloat.self)"))
    #expect(stack.contains("onHeightChange(height)"))
    #expect(stack.contains(".id(thread.id)"))
    #expect(stack.contains("await onResolveToggle(thread.id, $0)"))
    #expect(stack.contains("await onReply(thread.id, $0)"))
  }

  private func source(named relativePath: String) throws -> String {
    try String(contentsOf: previewableSourceURL(named: relativePath), encoding: .utf8)
  }

  private func previewableSourceURL(named relativePath: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
  }

  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
