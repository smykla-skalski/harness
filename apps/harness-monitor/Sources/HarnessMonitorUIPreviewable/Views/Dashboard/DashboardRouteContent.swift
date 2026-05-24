import HarnessMonitorKit
import SwiftUI

struct DashboardRouteContent: View {
  let route: DashboardWindowRoute
  @Binding var selectedRoute: DashboardWindowRoute
  let store: HarnessMonitorStore
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  @State private var reviewsSearchAutomationCommand = AppSearchAutomationCommand.idle
  @State private var notificationsHasBeenMounted = false
  @State private var diagnosticsHasBeenMounted = false
  @State private var policyCanvasHasBeenMounted = false
  @State private var reviewsHasBeenMounted = false

  private var isTaskBoardVisible: Bool { route == .taskBoard }
  private var isNotificationsVisible: Bool { route == .notifications }
  private var isDiagnosticsVisible: Bool { route == .diagnostics }
  private var isPolicyCanvasVisible: Bool { route == .policyCanvas }
  private var isReviewsVisible: Bool { route == .reviews }
  private var reviewsSearchAutomation: AppSearchAutomationCommand? {
    HarnessMonitorUITestEnvironment.isPerfScenarioActive
      ? reviewsSearchAutomationCommand
      : nil
  }

  var body: some View {
    ZStack {
      DashboardTaskBoardRouteView(
        store: store,
        dashboardUI: dashboardUI,
        sessionCatalog: sessionCatalog
      )
      .opacity(isTaskBoardVisible ? 1 : 0)
      .allowsHitTesting(isTaskBoardVisible)
      .accessibilityHidden(!isTaskBoardVisible)

      if notificationsHasBeenMounted || isNotificationsVisible {
        DashboardNotificationsRouteView(
          store: store,
          dashboardUI: dashboardUI
        )
        .opacity(isNotificationsVisible ? 1 : 0)
        .allowsHitTesting(isNotificationsVisible)
        .accessibilityHidden(!isNotificationsVisible)
        .onAppear {
          notificationsHasBeenMounted = true
        }
      }

      if policyCanvasHasBeenMounted || isPolicyCanvasVisible {
        PolicyCanvasView(store: store, dashboardUI: dashboardUI)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .opacity(isPolicyCanvasVisible ? 1 : 0)
          .allowsHitTesting(isPolicyCanvasVisible)
          .accessibilityHidden(!isPolicyCanvasVisible)
          .onAppear {
            policyCanvasHasBeenMounted = true
          }
      }

      if diagnosticsHasBeenMounted || isDiagnosticsVisible {
        DashboardDiagnosticsRouteView(
          store: store,
          selectedRoute: route
        )
        .opacity(isDiagnosticsVisible ? 1 : 0)
        .allowsHitTesting(isDiagnosticsVisible)
        .accessibilityHidden(!isDiagnosticsVisible)
        .onAppear {
          diagnosticsHasBeenMounted = true
        }
      }

      if reviewsHasBeenMounted || isReviewsVisible {
        DashboardReviewsRouteView(
          store: store,
          selectedRoute: $selectedRoute,
          searchAutomationCommand: reviewsSearchAutomation
        )
        .opacity(isReviewsVisible ? 1 : 0)
        .allowsHitTesting(isReviewsVisible)
        .accessibilityHidden(!isReviewsVisible)
        .onAppear {
          reviewsHasBeenMounted = true
        }
      }
    }
    .modifier(
      DashboardWindowPerfScenarioScript(
        selectedRoute: $selectedRoute,
        searchAutomationCommand: $reviewsSearchAutomationCommand
      )
    )
  }
}

struct DashboardTaskBoardRouteView: View {
  let store: HarnessMonitorStore
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  @State private var taskBoardInboxSnapshot = TaskBoardInboxSnapshot(
    generatedAt: nil,
    isFromCache: true
  )
  @State private var perfScrollPosition = ScrollPosition()
  private let perfScrollHookEnabled = HarnessMonitorPerfDashboardScrollBus.isActive()

  private var visibleTaskBoardSessions: [SessionSummary] {
    let visible = store.visibleSessions
    return visible.isEmpty ? sessionCatalog.recentSessions : visible
  }

  private var taskBoardInboxSessionIDs: [String] {
    visibleTaskBoardSessions.map(\.sessionId)
  }

  var body: some View {
    Group {
      if perfScrollHookEnabled {
        dashboardScrollingContent(scrollPosition: $perfScrollPosition)
      } else {
        dashboardExpandedContent
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      guard perfScrollHookEnabled else { return }
      HarnessMonitorPerfDashboardScrollBus.recordTrigger(edge: "view.appear")
    }
    .task(id: taskBoardInboxSessionIDs) {
      await refreshVisibleTaskBoardInboxSnapshot()
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: HarnessMonitorPerfDashboardScrollBus.scrollToBottom
      )
    ) { _ in
      guard perfScrollHookEnabled else { return }
      HarnessMonitorPerfDashboardScrollBus.recordTrigger(edge: "bottom")
      withAnimation(.easeOut(duration: 0.6)) {
        perfScrollPosition = ScrollPosition(edge: .bottom)
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: HarnessMonitorPerfDashboardScrollBus.scrollToTop
      )
    ) { _ in
      guard perfScrollHookEnabled else { return }
      HarnessMonitorPerfDashboardScrollBus.recordTrigger(edge: "top")
      withAnimation(.easeOut(duration: 0.6)) {
        perfScrollPosition = ScrollPosition(edge: .top)
      }
    }
  }

  private var taskBoardOverviewContent: some View {
    TaskBoardOverviewHost(
      scope: .dashboard,
      store: store,
      snapshot: taskBoardInboxSnapshot,
      taskBoardItems: dashboardUI.taskBoardItems,
      decisions: store.supervisorOpenDecisions,
      orchestratorStatus: dashboardUI.taskBoardOrchestratorStatus,
      evaluationSummary: dashboardUI.taskBoardEvaluationSummary,
      isActionInFlight: dashboardUI.isBusy
    )
  }

  private var dashboardExpandedContent: some View {
    GeometryReader { proxy in
      ScrollView(.vertical) {
        TaskBoardDashboardViewportLayout(viewportHeight: proxy.size.height) {
          taskBoardOverviewContent
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .scrollBounceBehavior(.basedOnSize)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardScrollView)
      .accessibilityLabel("Dashboard")
    }
  }

  private func dashboardScrollingContent(
    scrollPosition: Binding<ScrollPosition>? = nil
  ) -> some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: 0,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.dashboardScrollView,
      scrollSurfaceLabel: "Dashboard",
      scrollPosition: scrollPosition
    ) {
      VStack(alignment: .leading, spacing: 24) {
        taskBoardOverviewContent
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func refreshVisibleTaskBoardInboxSnapshot() async {
    let snapshot = await store.loadCachedTaskBoardInboxSnapshot(
      sessions: visibleTaskBoardSessions,
      limit: 120
    )
    guard !Task.isCancelled else { return }
    taskBoardInboxSnapshot = snapshot
  }
}
