import HarnessMonitorKit
import SwiftUI

public struct DashboardWindowView: View {
  public let store: HarnessMonitorStore
  public let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  public let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  public let history: GlobalWindowNavigationHistory
  @AppStorage(HarnessMonitorMCPSettingsDefaults.registryHostEnabledKey)
  var mcpRegistryHostEnabled = HarnessMonitorMCPSettingsDefaults.registryHostEnabledDefault
  @SceneStorage("dashboard.route")
  var persistedRouteRaw = DashboardWindowRoute.taskBoard.rawValue
  @SceneStorage("dashboard.columnVisibility")
  var persistedColumnVisibilityRaw = SessionColumnVisibilityCodec.encode(.doubleColumn)
  @SceneStorage("dashboard.sidebarWidth")
  var persistedSidebarWidth = 220.0
  @Environment(\.openWindow)
  var openWindow
  @State private var handledHistoryRestoreRequestID = 0

  public init(
    store: HarnessMonitorStore,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice,
    sessionCatalog: HarnessMonitorStore.SessionCatalogSlice,
    history: GlobalWindowNavigationHistory? = nil
  ) {
    self.store = store
    self.dashboardUI = dashboardUI
    self.sessionCatalog = sessionCatalog
    self.history = history ?? GlobalWindowNavigationHistory(store: store)
  }

  var selectedRoute: DashboardWindowRoute {
    get { DashboardWindowRoute(rawValue: persistedRouteRaw) ?? .taskBoard }
    nonmutating set { persistedRouteRaw = newValue.rawValue }
  }

  var selectedRouteBinding: Binding<DashboardWindowRoute> {
    Binding(
      get: { selectedRoute },
      set: { selectedRoute = $0 }
    )
  }

  var columnVisibility: NavigationSplitViewVisibility {
    let decodedVisibility = SessionColumnVisibilityCodec.decode(columnVisibilityRaw)
    return decodedVisibility == .all ? .doubleColumn : decodedVisibility
  }

  func makeProfilingAttributes(
    route: DashboardWindowRoute,
    columnVisibility: NavigationSplitViewVisibility
  ) -> [String: String] {
    [
      "harness.view.surface": "dashboard",
      "harness.view.column_visibility": SessionColumnVisibilityCodec.encode(columnVisibility),
      "harness.view.selected_route": route.rawValue,
    ]
  }

  func dashboardStatusSummaryModel(
    route: DashboardWindowRoute
  ) -> SessionStatusSummaryModel {
    let metrics = store.connectionMetrics
    return SessionStatusSummaryModel(
      metrics: metrics,
      sourceTitle: "Dashboard",
      sourceSystemImage: "square.grid.2x2",
      sourceTint: harnessSidebarStatusSourceTint(for: metrics),
      statusStripState: harnessSidebarStatusStripState(
        for: store,
        isMCPRegistryHostEnabled: mcpRegistryHostEnabled
      ),
      connectionSummaryText: harnessSidebarConnectionSummaryText(for: store),
      sessionStatusTitle: route.title
    )
  }

  var sidebarWidth: Double {
    get { persistedSidebarWidth }
    nonmutating set { persistedSidebarWidth = newValue }
  }

  var columnVisibilityRaw: String {
    get { persistedColumnVisibilityRaw }
    nonmutating set { persistedColumnVisibilityRaw = newValue }
  }

  var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: { columnVisibility },
      set: { newValue in
        let storedVisibility: NavigationSplitViewVisibility =
          newValue == .all ? .doubleColumn : newValue
        let encodedVisibility = SessionColumnVisibilityCodec.encode(storedVisibility)
        guard columnVisibilityRaw != encodedVisibility else {
          return
        }
        columnVisibilityRaw = encodedVisibility
      }
    )
  }

  var windowNavigationState: WindowNavigationState {
    let navigationState = WindowNavigationState(
      canGoBack: history.canGoBack,
      canGoForward: history.canGoForward
    )
    navigationState.setHandlers(
      back: { history.navigateBack() },
      forward: { history.navigateForward() }
    )
    return navigationState
  }

  public var body: some View {
    // Resolve once per body eval and reuse — the computed properties decode
    // the SceneStorage raw strings and `profilingAttributes` would re-encode
    // them. During audit scroll the dashboard body re-runs hundreds of
    // times per second, so deduping these decode/encode pairs is real work.
    let route = selectedRoute
    let resolvedColumnVisibility = columnVisibility
    return ViewBodySignposter.trace(
      Self.self,
      "DashboardWindowView",
      attributes: makeProfilingAttributes(
        route: route,
        columnVisibility: resolvedColumnVisibility
      )
    ) {
      HarnessMonitorSidebarDetailLayout(
        columnVisibility: columnVisibilityBinding,
        sidebarWidth: sidebarWidth
      ) {
        DashboardSidebar(
          store: store,
          selectedRoute: selectedRouteBinding,
          recentSessions: sessionCatalog.recentSessions,
          statusModel: dashboardStatusSummaryModel(route: route)
        )
      } detail: {
        DashboardBannerStack(store: store) {
          DashboardRouteContent(
            route: route,
            selectedRoute: selectedRouteBinding,
            store: store,
            dashboardUI: dashboardUI,
            sessionCatalog: sessionCatalog
          )
        }
        .navigationTitle("Dashboard")
        .navigationSubtitle(route.title)
      }
      .harnessFocusedSceneValue(\.windowNavigation, windowNavigationState)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardWindowRoot)
      .toolbar {
        DashboardWindowToolbar(
          store: store,
          navigation: windowNavigationState,
          showsQuickActions: route == .taskBoard,
          sleepPreventionPresentation: SleepPreventionToolbarPresentation(
            isEnabled: store.contentUI.toolbar.sleepPreventionEnabled
          )
        )
      }
      .onChange(of: selectedRoute) { _, newRoute in
        history.recordDashboardRoute(newRoute)
      }
      .task(id: history.pendingDashboardRestoreRequest) {
        await applyPendingHistoryRestoreIfNeeded()
      }
      .task {
        history.installNavigator(openWindow: openWindow)
        history.installDashboardStateIfNeeded(route: route)
        HarnessMonitorUITestTrace.record(
          component: "dashboard.window",
          event: "mounted",
          details: [
            "selected_route": selectedRoute.rawValue,
            "recent_session_count": String(sessionCatalog.recentSessions.count),
          ]
        )
      }
      .modifier(DashboardPerfRouteHook(selectedRouteBinding: selectedRouteBinding))
    }
  }

  @MainActor
  func applyPendingHistoryRestoreIfNeeded() async {
    guard let request = history.pendingDashboardRestoreRequest else {
      return
    }
    guard request.requestID != handledHistoryRestoreRequestID else {
      return
    }
    handledHistoryRestoreRequestID = request.requestID
    if selectedRoute != request.route {
      selectedRoute = request.route
    }
    await Task.yield()
    history.finishDashboardRestoreRequest(request.requestID)
  }
}
