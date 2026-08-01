import Testing

@testable import HarnessMonitorUIPreviewable

extension TaskBoardRouteContentSourceTests {
  @Test("Task board lanes expand beyond the fixed baseline when the dashboard is taller")
  func taskBoardLanesExpandBeyondFixedBaselineWhenDashboardIsTaller() throws {
    let dashboardSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardRouteContent.swift"
    )
    let overviewHostSource = try taskBoardSourceFile(named: "TaskBoardOverviewHost.swift")
    let overviewSource = try taskBoardSourceFile(named: "TaskBoardOverviewView.swift")
    let overviewSupportSource = try taskBoardSourceFile(named: "TaskBoardOverviewSupport.swift")
    let laneChromeSource = try taskBoardSourceFile(named: "TaskBoardLaneChrome.swift")

    #expect(dashboardSource.contains("dashboardExpandedContent"))
    #expect(dashboardSource.contains("GeometryReader { proxy in"))
    #expect(dashboardSource.contains("ScrollView(.vertical)"))
    #expect(dashboardSource.contains("TaskBoardDashboardViewportLayout"))
    #expect(dashboardSource.contains(".scrollBounceBehavior(.basedOnSize)"))
    #expect(overviewHostSource.contains("fillsAvailableHeight: scope.fillsAvailableHeight"))
    #expect(overviewSource.contains("fillsAvailableHeight ? .infinity : nil"))
    #expect(overviewSupportSource.contains("struct TaskBoardDashboardViewportLayout: Layout"))
    #expect(overviewSupportSource.contains("max(intrinsic.height, max(viewportHeight, 0))"))
    #expect(!overviewSupportSource.contains("TaskBoardFillLastLayout"))
    #expect(!overviewSupportSource.contains("usesProposedHeightForMeasurement"))
    #expect(
      overviewSupportSource.contains("let height = max(measuredHeight, proposal.height ?? 0)"))
    #expect(laneChromeSource.contains("idealHeight: metrics.laneFixedHeight"))
    #expect(laneChromeSource.contains("minHeight: metrics.laneFixedHeight"))
    #expect(laneChromeSource.contains("maxHeight: .infinity"))
  }

  @Test("Dashboard retains mounted route state without retaining Reviews publishers")
  func dashboardRetainsMountedAuxiliaryRouteState() throws {
    let dashboardSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardRouteContent.swift"
    )
    let dashboardWindowSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardWindowView.swift"
    )
    let policyCanvasSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardPolicyCanvasRouteView.swift"
    )

    #expect(dashboardSource.contains("DashboardRetainedRouteLayout(selectedRoute: route)"))
    #expect(dashboardSource.contains("private struct DashboardRetainedAuxiliaryRoute"))
    #expect(dashboardSource.contains("@State private var hasBeenMounted = false"))
    #expect(dashboardSource.contains("private var isAuditVisible"))
    #expect(dashboardSource.contains("private var isDiagnosticsVisible"))
    #expect(dashboardSource.contains("private var isDebuggingVisible"))
    #expect(dashboardSource.contains("private var isPolicyCanvasVisible"))
    #expect(dashboardSource.contains("private var isReviewsVisible"))
    #expect(
      dashboardSource.contains(
        "DashboardRetainedAuxiliaryRoute(isVisible: isAuditVisible)"
      )
    )
    #expect(
      dashboardSource.contains(
        "DashboardRetainedAuxiliaryRoute(isVisible: isPolicyCanvasVisible)"
      )
    )
    #expect(
      dashboardSource.contains(
        "DashboardRetainedAuxiliaryRoute(isVisible: isDiagnosticsVisible)"
      )
    )
    #expect(
      dashboardSource.contains(
        "DashboardRetainedAuxiliaryRoute(isVisible: isDebuggingVisible)"
      )
    )
    #expect(dashboardSource.contains("if hasBeenMounted || isVisible"))
    #expect(dashboardSource.contains(".opacity(isVisible ? 1 : 0)"))
    #expect(dashboardSource.contains(".allowsHitTesting(isVisible)"))
    #expect(dashboardSource.contains(".accessibilityHidden(!isVisible)"))
    #expect(dashboardSource.contains("policyCanvasViewModelStore: policyCanvasViewModelStore"))
    #expect(
      dashboardWindowSource.contains(
        "@StateObject private var policyCanvasViewModelStore"
      )
    )
    #expect(
      policyCanvasSource.contains(
        "@ObservedObject private var policyCanvasViewModelStore"
      )
    )
    #expect(dashboardSource.contains("if isReviewsVisible {"))
    #expect(
      !dashboardSource.contains(
        "DashboardRetainedAuxiliaryRoute(isVisible: isReviewsVisible)"
      )
    )
    #expect(!dashboardSource.contains("selectedAuxiliaryRoute"))
  }
}
