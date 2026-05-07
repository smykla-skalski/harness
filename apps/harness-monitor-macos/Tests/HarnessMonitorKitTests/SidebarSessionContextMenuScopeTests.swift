import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Sidebar session context menu scope")
struct SidebarSessionContextMenuScopeTests {
  @Test("selected row uses all selected sessions with pluralized labels")
  func selectedRowUsesAllSelectedSessions() {
    let scope = SidebarSessionContextMenuScope.resolve(
      rowSession: PreviewFixtures.summary,
      selectedSessionIDs: [
        PreviewFixtures.summary.sessionId,
        PreviewFixtures.signalRegressionSecondarySummary.sessionId,
      ],
      orderedVisibleSessions: PreviewFixtures.signalRegressionSessions,
      bookmarkedSessionIDs: []
    )

    #expect(
      scope.sessionIDs
        == [
          PreviewFixtures.summary.sessionId,
          PreviewFixtures.signalRegressionSecondarySummary.sessionId,
        ]
    )
    #expect(scope.bookmarkLabel == "Bookmark Sessions")
    #expect(scope.copyTitleLabel == "Copy Titles")
    #expect(scope.copyTitleText == "Harness Monitor Cockpit\nSignal retention verification")
    #expect(scope.copySessionIDLabel == "Copy Session IDs")
    #expect(
      scope.copySessionIDText
        == PreviewFixtures.summary.sessionId
        + "\n"
        + PreviewFixtures.signalRegressionSecondarySummary.sessionId
    )
    #expect(scope.removeLabel == "Remove Sessions...")
  }

  @Test("non-selected row keeps context menu scoped to that row")
  func nonSelectedRowKeepsSingleRowScope() {
    let scope = SidebarSessionContextMenuScope.resolve(
      rowSession: PreviewFixtures.signalRegressionSecondarySummary,
      selectedSessionIDs: [PreviewFixtures.summary.sessionId],
      orderedVisibleSessions: PreviewFixtures.signalRegressionSessions,
      bookmarkedSessionIDs: [PreviewFixtures.summary.sessionId]
    )

    #expect(scope.sessionIDs == [PreviewFixtures.signalRegressionSecondarySummary.sessionId])
    #expect(scope.bookmarkLabel == "Bookmark")
    #expect(scope.copyTitleLabel == "Copy Title")
    #expect(scope.copySessionIDLabel == "Copy Session ID")
    #expect(scope.removeLabel == "Remove Session...")
  }

  @Test("all bookmarked multi-selection offers plural remove bookmarks")
  func fullyBookmarkedMultiSelectionOffersRemoveBookmarks() {
    let scope = SidebarSessionContextMenuScope.resolve(
      rowSession: PreviewFixtures.summary,
      selectedSessionIDs: [
        PreviewFixtures.summary.sessionId,
        PreviewFixtures.signalRegressionSecondarySummary.sessionId,
      ],
      orderedVisibleSessions: PreviewFixtures.signalRegressionSessions,
      bookmarkedSessionIDs: [
        PreviewFixtures.summary.sessionId,
        PreviewFixtures.signalRegressionSecondarySummary.sessionId,
      ]
    )

    #expect(scope.bookmarkLabel == "Remove Bookmarks")
    #expect(scope.bookmarkTargets.map(\.sessionID) == scope.sessionIDs)
  }
}
