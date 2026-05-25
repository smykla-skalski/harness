import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension DashboardReviewsRouteViewTests {
  @Test("route source records and restores dashboard history")
  func routeSourceRecordsAndRestoresDashboardHistory() throws {
    let source = try dashboardReviewsRouteSource()
    let filesModeSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsFilesMode.swift")
    let taskLifetimeSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+TaskLifetime.swift")

    #expect(source.contains("@Environment(\\.globalWindowNavigationHistory)"))
    #expect(
      source.contains(".task(id: windowNavigationHistory?.pendingDashboardReviewsRestoreRequest)")
    )
    #expect(source.contains("recordCurrentHistorySelectionIfVisible()"))
    #expect(
      source.contains(
        "Task {\n          await applyPendingDashboardReviewsRestoreIfNeeded()"
      )
    )
    #expect(filesModeSource.contains("struct DashboardReviewsHistorySelection"))
    #expect(
      taskLifetimeSource.contains("recordDashboardSelection(currentDashboardHistorySelection)")
    )
    #expect(taskLifetimeSource.contains("finishDashboardReviewsRestoreRequest(request.requestID)"))
  }
}
