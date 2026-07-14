import HarnessMonitorKit
import SwiftUI

struct DashboardRouteContent: View, Equatable {
  let route: DashboardWindowRoute
  @Binding var selectedRoute: DashboardWindowRoute
  let store: HarnessMonitorStore
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  @State private var reviewsSearchAutomationCommand = AppSearchAutomationCommand.idle
  @State private var auditHasBeenMounted = false
  @State private var diagnosticsHasBeenMounted = false
  @State private var debuggingHasBeenMounted = false
  @State private var policyCanvasHasBeenMounted = false

  // Skip rebuilding the retained route subtree when only the window's column
  // visibility animates: the route and the three @Observable inputs are
  // unchanged, so the expensive hidden routes must not re-evaluate. Intra-slice
  // data changes still re-run the affected route bodies through observation, and
  // @State (mount flags, search command) self-invalidates regardless of this ==.
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.route == rhs.route
      && lhs.store === rhs.store
      && lhs.dashboardUI === rhs.dashboardUI
      && lhs.sessionCatalog === rhs.sessionCatalog
  }

  private var isTaskBoardVisible: Bool { route == .taskBoard }
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
        sessionCatalog: sessionCatalog,
        isRouteVisible: isTaskBoardVisible
      )
      .layoutValue(key: DashboardRetainedRouteKey.self, value: .taskBoard)
      .opacity(isTaskBoardVisible ? 1 : 0)
      .allowsHitTesting(isTaskBoardVisible)
      .accessibilityHidden(!isTaskBoardVisible)

      if auditHasBeenMounted || isAuditVisible {
        DashboardAuditRouteView(
          store: store,
          dashboardUI: dashboardUI
        )
        .layoutValue(key: DashboardRetainedRouteKey.self, value: .audit)
        .opacity(isAuditVisible ? 1 : 0)
        .allowsHitTesting(isAuditVisible)
        .accessibilityHidden(!isAuditVisible)
        .onAppear {
          auditHasBeenMounted = true
        }
      }

      if policyCanvasHasBeenMounted || isPolicyCanvasVisible {
        DashboardPolicyCanvasRouteView(
          store: store,
          dashboardUI: dashboardUI,
          isRouteVisible: isPolicyCanvasVisible
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutValue(key: DashboardRetainedRouteKey.self, value: .policyCanvas)
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
        .layoutValue(key: DashboardRetainedRouteKey.self, value: .diagnostics)
        .opacity(isDiagnosticsVisible ? 1 : 0)
        .allowsHitTesting(isDiagnosticsVisible)
        .accessibilityHidden(!isDiagnosticsVisible)
        .onAppear {
          diagnosticsHasBeenMounted = true
        }
      }

      if debuggingHasBeenMounted || isDebuggingVisible {
        DashboardDebuggingRouteView()
          .layoutValue(key: DashboardRetainedRouteKey.self, value: .debugging)
          .opacity(isDebuggingVisible ? 1 : 0)
          .allowsHitTesting(isDebuggingVisible)
          .accessibilityHidden(!isDebuggingVisible)
          .onAppear {
            debuggingHasBeenMounted = true
          }
      }

      // Keep reviews unretained so its toolbar search and focused-scene command
      // publishers disappear when the user leaves the route. The canvas route
      // remains retained because it owns in-progress document state.
      if isReviewsVisible {
        DashboardReviewsRouteView(
          store: store,
          selectedRoute: $selectedRoute,
          searchAutomationCommand: reviewsSearchAutomation
        )
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
  let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  let isRouteVisible: Bool
  @AppStorage(TaskBoardOperationsInspectorVisibility.storageKey)
  private var operationsInspectorVisible = TaskBoardOperationsInspectorVisibility.defaultValue
  @State private var taskBoardInboxSnapshot = TaskBoardInboxSnapshot(
    generatedAt: nil,
    isFromCache: true
  )
  @State private var perfScrollPosition = ScrollPosition()
  @State private var operationsInspectorDispatcher =
    TaskBoardOperationsInspectorFocusDispatcher()
  @State private var policyWorkspaceLoadState = TaskBoardPolicyWorkspaceLoadState()
  private let perfScrollHookEnabled = HarnessMonitorPerfDashboardScrollBus.isActive()

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
    HStack(spacing: 0) {
      taskBoardMainContent
      TaskBoardOperationsInspector(
        store: store,
        taskBoardItems: dashboardUI.taskBoardItems,
        isVisible: operationsInspectorVisible && isRouteVisible
      )
    }
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
    .onAppear {
      operationsInspectorDispatcher.toggleInspector = toggleOperationsInspector
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
      snapshot: taskBoardInboxSnapshot,
      taskBoardItems: dashboardUI.taskBoardItems,
      decisions: store.supervisorOpenDecisions,
      orchestratorStatus: dashboardUI.taskBoardOrchestratorStatus,
      evaluationSummary: dashboardUI.taskBoardEvaluationSummary,
      isActionInFlight: dashboardUI.isBusy || dashboardUI.connectionState != .online,
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

  @MainActor
  private func toggleOperationsInspector() {
    operationsInspectorVisible.toggle()
  }
}
