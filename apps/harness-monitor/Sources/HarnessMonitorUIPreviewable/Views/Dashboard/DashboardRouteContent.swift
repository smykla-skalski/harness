import HarnessMonitorKit
import SwiftUI

struct DashboardRouteContent: View, Equatable {
  let route: DashboardWindowRoute
  @Binding var selectedRoute: DashboardWindowRoute
  let store: HarnessMonitorStore
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  let history: GlobalWindowNavigationHistory
  let policyCanvasViewModelStore: DashboardPolicyCanvasViewModelStore
  let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  let operationsInspectorVisible: Bool
  let operationsInspectorDispatcher: TaskBoardOperationsInspectorFocusDispatcher
  @State private var reviewsSearchAutomationCommand = AppSearchAutomationCommand.idle

  // Skip rebuilding the board and selected route when only the window's column
  // visibility animates. Intra-slice data changes still re-run the affected
  // route bodies through observation.
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.route == rhs.route
      && lhs.store === rhs.store
      && lhs.dashboardUI === rhs.dashboardUI
      && lhs.history === rhs.history
      && lhs.policyCanvasViewModelStore === rhs.policyCanvasViewModelStore
      && lhs.sessionCatalog === rhs.sessionCatalog
      && lhs.operationsInspectorVisible == rhs.operationsInspectorVisible
      && lhs.operationsInspectorDispatcher === rhs.operationsInspectorDispatcher
  }

  private var isTaskBoardVisible: Bool { route == .taskBoard }
  private var isAgentsVisible: Bool { route == .agents }
  private var isAuditVisible: Bool { route == .audit }
  private var isDiagnosticsVisible: Bool { route == .diagnostics }
  private var isDebuggingVisible: Bool { route == .debugging }
  private var isPolicyCanvasVisible: Bool { route == .policyCanvas }
  private var isReviewsVisible: Bool { route == .reviews }
  private var reviewsSearchAutomation: AppSearchAutomationCommand? {
    HarnessMonitorUITestEnvironment.isPerfScenarioActive
      ? reviewsSearchAutomationCommand
      : nil
  }

  var body: some View {
    let _ = HarnessMonitorPerfTrace.countBodyEval("DashboardRouteContent")
    DashboardRetainedRouteLayout(selectedRoute: route) {
      DashboardTaskBoardRouteView(
        store: store,
        dashboardUI: dashboardUI,
        history: history,
        sessionCatalog: sessionCatalog,
        isRouteVisible: isTaskBoardVisible,
        operationsInspectorVisible: operationsInspectorVisible,
        operationsInspectorDispatcher: operationsInspectorDispatcher
      )
      .layoutValue(key: DashboardRetainedRouteKey.self, value: .taskBoard)
      .opacity(isTaskBoardVisible ? 1 : 0)
      .allowsHitTesting(isTaskBoardVisible)
      .accessibilityHidden(!isTaskBoardVisible)
      .modifier(DashboardRetainedRouteGeometryIsolation())

      DashboardRetainedAuxiliaryRoute(isVisible: isAgentsVisible) {
        DashboardAgentsRouteView(
          store: store,
          sessions: sessionCatalog.sessions,
          history: history,
          isRouteVisible: isAgentsVisible
        )
      }
      .layoutValue(key: DashboardRetainedRouteKey.self, value: .agents)

      DashboardRetainedAuxiliaryRoute(isVisible: isAuditVisible) {
        DashboardAuditRouteView(
          store: store,
          dashboardUI: dashboardUI,
          history: history
        )
      }
      .modifier(DashboardRetainedRouteGeometryIsolation())
      .layoutValue(key: DashboardRetainedRouteKey.self, value: .audit)

      DashboardRetainedAuxiliaryRoute(isVisible: isPolicyCanvasVisible) {
        DashboardPolicyCanvasRouteView(
          store: store,
          dashboardUI: dashboardUI,
          policyCanvasViewModelStore: policyCanvasViewModelStore,
          isRouteVisible: isPolicyCanvasVisible
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .modifier(DashboardRetainedRouteGeometryIsolation())
      .layoutValue(key: DashboardRetainedRouteKey.self, value: .policyCanvas)

      DashboardRetainedAuxiliaryRoute(isVisible: isDiagnosticsVisible) {
        DashboardDiagnosticsRouteView(
          store: store,
          selectedRoute: route
        )
      }
      .modifier(DashboardRetainedRouteGeometryIsolation())
      .layoutValue(key: DashboardRetainedRouteKey.self, value: .diagnostics)

      DashboardRetainedAuxiliaryRoute(isVisible: isDebuggingVisible) {
        DashboardDebuggingRouteView()
      }
      .modifier(DashboardRetainedRouteGeometryIsolation())
      .layoutValue(key: DashboardRetainedRouteKey.self, value: .debugging)

      // Reviews intentionally leaves the tree when its route closes so its
      // focused-scene command and search publishers cannot remain active.
      if isReviewsVisible {
        DashboardReviewsRouteView(
          store: store,
          selectedRoute: $selectedRoute,
          searchAutomationCommand: reviewsSearchAutomation
        )
        .modifier(DashboardRetainedRouteGeometryIsolation())
        .layoutValue(key: DashboardRetainedRouteKey.self, value: .reviews)
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

private struct DashboardRetainedRouteGeometryIsolation: ViewModifier {
  func body(content: Content) -> some View {
    content.geometryGroup()
  }
}

private struct DashboardRetainedAuxiliaryRoute<Content: View>: View {
  let isVisible: Bool
  let content: Content
  @State private var hasBeenMounted = false

  init(
    isVisible: Bool,
    @ViewBuilder content: () -> Content
  ) {
    self.isVisible = isVisible
    self.content = content()
  }

  var body: some View {
    if hasBeenMounted || isVisible {
      content
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .onAppear {
          hasBeenMounted = true
        }
    }
  }
}

private struct DashboardRetainedRouteLayout: Layout {
  let selectedRoute: DashboardWindowRoute

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    selectedSubview(in: subviews)?.sizeThatFits(proposal) ?? .zero
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    selectedSubview(in: subviews)?.place(
      at: bounds.origin,
      proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
    )
  }

  private func selectedSubview(in subviews: Subviews) -> LayoutSubview? {
    subviews.first { subview in
      subview[DashboardRetainedRouteKey.self] == selectedRoute
    } ?? subviews.first
  }
}

private struct DashboardRetainedRouteKey: LayoutValueKey {
  static let defaultValue: DashboardWindowRoute? = nil
}

struct DashboardTaskBoardRouteView: View {
  let store: HarnessMonitorStore
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  let history: GlobalWindowNavigationHistory
  let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  let isRouteVisible: Bool
  let operationsInspectorVisible: Bool
  let operationsInspectorDispatcher: TaskBoardOperationsInspectorFocusDispatcher
  @State private var taskBoardInboxSnapshot = TaskBoardInboxSnapshot(
    generatedAt: nil,
    isFromCache: true
  )
  @State private var perfScrollPosition = ScrollPosition()
  @State private var policyWorkspaceLoadState = TaskBoardPolicyWorkspaceLoadState()
  private let perfScrollHookEnabled = HarnessMonitorPerfDashboardScrollBus.isActiveAtLaunch

  private var visibleTaskBoardSessions: [SessionSummary] {
    let visible = store.visibleSessions
    return visible.isEmpty ? sessionCatalog.recentSessions : visible
  }

  private var taskBoardInboxSessionIDs: [String] {
    visibleTaskBoardSessions.map(\.sessionId)
  }

  private var operationsInspectorFocus: TaskBoardOperationsInspectorFocus? {
    guard isRouteVisible else { return nil }
    return TaskBoardOperationsInspectorFocus(
      isVisible: operationsInspectorVisible,
      canToggle: true,
      dispatcher: operationsInspectorDispatcher
    )
  }

  var body: some View {
    let _ = HarnessMonitorPerfTrace.countBodyEval("DashboardTaskBoardRouteView")
    taskBoardMainContent
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onAppear {
        guard perfScrollHookEnabled else { return }
        HarnessMonitorPerfDashboardScrollBus.recordTrigger(edge: "view.appear")
      }
      .task(id: taskBoardInboxSessionIDs) {
        await refreshVisibleTaskBoardInboxSnapshot()
      }
      .onChange(of: isRouteVisible, initial: true) {
        updatePolicyWorkspaceLoad()
      }
      .onChange(of: dashboardUI.connectionState, initial: true) {
        updatePolicyWorkspaceLoad()
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

  @ViewBuilder private var taskBoardMainContent: some View {
    if perfScrollHookEnabled {
      dashboardScrollingContent(scrollPosition: $perfScrollPosition)
    } else {
      dashboardExpandedContent
    }
  }

  private var taskBoardOverviewContent: some View {
    TaskBoardOverviewHost(
      scope: .dashboard,
      store: store,
      navigationHistory: history,
      snapshot: taskBoardInboxSnapshot,
      taskBoardItems: dashboardUI.taskBoardItems,
      decisions: store.supervisorOpenDecisions,
      orchestratorStatus: dashboardUI.taskBoardOrchestratorStatus,
      evaluationSummary: dashboardUI.taskBoardEvaluationSummary,
      isActionInFlight: dashboardUI.isTaskBoardBusy || dashboardUI.connectionState != .online,
      isRouteVisible: isRouteVisible,
      showsOperationsPanel: false,
      isCommandFocusActive: isRouteVisible,
      operationsInspectorFocus: operationsInspectorFocus
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

  private func updatePolicyWorkspaceLoad() {
    let state = policyWorkspaceLoadState
    guard isRouteVisible, dashboardUI.connectionState == .online else {
      state.invalidate()
      return
    }
    guard
      let generation = state.beginLoad(
        hasWorkspace: dashboardUI.policyCanvasWorkspace != nil
      )
    else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Loading task-board policy workspace") {
        let workspace = await store.loadTaskBoardPolicyWorkspaceSnapshot()
        await MainActor.run {
          state.finishLoad(generation: generation) {
            if let workspace {
              store.adoptTaskBoardPolicyWorkspaceSnapshot(workspace)
            }
          }
        }
      }
    )
  }
}
