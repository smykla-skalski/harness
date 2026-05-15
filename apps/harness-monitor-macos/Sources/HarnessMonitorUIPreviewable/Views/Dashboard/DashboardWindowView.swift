import HarnessMonitorKit
import SwiftUI

public struct DashboardWindowView: View {
  public let store: HarnessMonitorStore
  public let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  public let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  @AppStorage(HarnessMonitorMCPSettingsDefaults.registryHostEnabledKey)
  private var mcpRegistryHostEnabled = HarnessMonitorMCPSettingsDefaults.registryHostEnabledDefault
  @SceneStorage("dashboard.route")
  private var persistedRouteRaw = DashboardWindowRoute.taskBoard.rawValue
  @SceneStorage("dashboard.columnVisibility")
  private var persistedColumnVisibilityRaw = SessionColumnVisibilityCodec.encode(.doubleColumn)
  @SceneStorage("dashboard.sidebarWidth")
  private var persistedSidebarWidth = 220.0

  public init(
    store: HarnessMonitorStore,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice,
    sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  ) {
    self.store = store
    self.dashboardUI = dashboardUI
    self.sessionCatalog = sessionCatalog
  }

  private var selectedRoute: DashboardWindowRoute {
    get { DashboardWindowRoute(rawValue: persistedRouteRaw) ?? .taskBoard }
    nonmutating set { persistedRouteRaw = newValue.rawValue }
  }

  private var selectedRouteBinding: Binding<DashboardWindowRoute> {
    Binding(
      get: { selectedRoute },
      set: { selectedRoute = $0 }
    )
  }

  private var columnVisibility: NavigationSplitViewVisibility {
    let decodedVisibility = SessionColumnVisibilityCodec.decode(columnVisibilityRaw)
    return decodedVisibility == .all ? .doubleColumn : decodedVisibility
  }

  private var profilingAttributes: [String: String] {
    [
      "harness.view.surface": "dashboard",
      "harness.view.column_visibility": SessionColumnVisibilityCodec.encode(columnVisibility),
      "harness.view.selected_route": selectedRoute.rawValue,
    ]
  }

  private var dashboardStatusSummaryModel: SessionStatusSummaryModel {
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
      sessionStatusTitle: selectedRoute.title
    )
  }

  private var dashboardToolbarModel: DashboardWindowToolbarModel {
    DashboardWindowToolbarModel(
      selectedRoute: selectedRoute,
      sleepPreventionPresentation: SleepPreventionToolbarPresentation(
        isEnabled: store.contentUI.toolbar.sleepPreventionEnabled
      )
    )
  }

  private var sidebarWidth: Double {
    get { persistedSidebarWidth }
    nonmutating set { persistedSidebarWidth = newValue }
  }

  private var columnVisibilityRaw: String {
    get { persistedColumnVisibilityRaw }
    nonmutating set { persistedColumnVisibilityRaw = newValue }
  }

  private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
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

  public var body: some View {
    ViewBodySignposter.trace(
      Self.self,
      "DashboardWindowView",
      attributes: profilingAttributes
    ) {
      HarnessMonitorSidebarDetailLayout(
        columnVisibility: columnVisibilityBinding,
        sidebarWidth: sidebarWidth
      ) {
        DashboardSidebar(
          selectedRoute: selectedRouteBinding,
          statusModel: dashboardStatusSummaryModel
        )
      } detail: {
        DashboardRouteContent(
          route: selectedRoute,
          store: store,
          dashboardUI: dashboardUI,
          sessionCatalog: sessionCatalog
        )
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardWindowRoot)
      .toolbar {
        DashboardWindowToolbar(
          store: store,
          model: dashboardToolbarModel
        )
      }
      .toolbarBackground(.visible, for: .windowToolbar)
      .task {
        HarnessMonitorUITestTrace.record(
          component: "dashboard.window",
          event: "mounted",
          details: [
            "selected_route": selectedRoute.rawValue,
            "recent_session_count": String(sessionCatalog.recentSessions.count),
          ]
        )
      }
    }
  }
}

private struct DashboardWindowToolbarModel: Equatable {
  let selectedRoute: DashboardWindowRoute
  let sleepPreventionPresentation: SleepPreventionToolbarPresentation

  var showsQuickActions: Bool {
    selectedRoute == .taskBoard
  }
}

private struct DashboardWindowToolbar: ToolbarContent {
  let store: HarnessMonitorStore
  let model: DashboardWindowToolbarModel

  @ToolbarContentBuilder
  var body: some ToolbarContent {
    HarnessMonitorWindowToolbar {
      ToolbarItemGroup(placement: .navigation) {
        if model.showsQuickActions {
          Button {
            store.presentedSheet = .newSession
          } label: {
            Label {
              Text("New Session")
            } icon: {
              Image(systemName: "plus.square")
                .frame(width: 14, height: 14)
            }
          }
          .help("New Session")
          .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardNewSessionButton)
          .harnessMCPButton(
            HarnessMonitorAccessibility.dashboardNewSessionButton,
            label: "New Session",
            hint: "Create a new session.",
            pressAction: { store.presentedSheet = .newSession }
          )

          Button {
            store.requestOpenFolder()
          } label: {
            Label {
              Text("Open Folder")
            } icon: {
              Image(systemName: "folder")
                .frame(width: 14, height: 14)
            }
          }
          .help("Open Folder")
          .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardOpenFolderButton)
          .harnessMCPButton(
            HarnessMonitorAccessibility.dashboardOpenFolderButton,
            label: "Open Folder",
            hint: "Open a project folder.",
            pressAction: { store.requestOpenFolder() }
          )
        }
      }
    } automatic: {
      ToolbarItemGroup(placement: .automatic) {}
    } primaryAction: {
      ToolbarItem(placement: .primaryAction) {
        SleepPreventionToolbarButton(
          store: store,
          presentation: model.sleepPreventionPresentation
        )
      }
    }
  }
}

private enum DashboardWindowRoute: String, CaseIterable, Identifiable {
  case taskBoard
  case policyCanvas

  var id: String { rawValue }

  var title: String {
    switch self {
    case .taskBoard:
      "Task Board"
    case .policyCanvas:
      "Policy Canvas"
    }
  }

  var systemImage: String {
    switch self {
    case .taskBoard:
      "square.grid.2x2"
    case .policyCanvas:
      "point.3.connected.trianglepath.dotted"
    }
  }
}

private struct DashboardSidebar: View {
  @Binding var selectedRoute: DashboardWindowRoute
  let statusModel: SessionStatusSummaryModel
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex

  private var dashboardSelectionBinding: Binding<DashboardWindowRoute?> {
    Binding(
      get: { selectedRoute },
      set: { newValue in
        guard let newValue else { return }
        selectedRoute = newValue
      }
    )
  }

  var body: some View {
    ViewBodySignposter.trace(
      Self.self,
      "DashboardSidebar",
      attributes: [
        "harness.view.selected_route": selectedRoute.rawValue,
        "harness.view.route_count": String(DashboardWindowRoute.allCases.count),
      ]
    ) {
      HarnessMonitorSidebar(
        accessibilityIdentifier: HarnessMonitorAccessibility.dashboardSidebar,
        statusModel: statusModel
      ) {
        List(selection: dashboardSelectionBinding) {
          ForEach(DashboardWindowRoute.allCases, id: \.id) { route in
            let isSelected = selectedRoute == route
            SessionSidebarRow(
              title: route.title,
              systemImage: route.systemImage
            )
            .tag(route)
            .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardWindowRoute(route.rawValue))
            .accessibilityValue(isSelected ? "selected" : "not selected")
          }
        }
        .harnessMonitorSidebarListChrome(
          rowSize: harnessSidebarRowSize(for: textSizeIndex)
        )
      }
    }
  }
}

private struct DashboardRouteContent: View {
  let route: DashboardWindowRoute
  let store: HarnessMonitorStore
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice

  var body: some View {
    Group {
      switch route {
      case .taskBoard:
        DashboardTaskBoardRouteView(
          store: store,
          dashboardUI: dashboardUI,
          sessionCatalog: sessionCatalog
        )
      case .policyCanvas:
        PolicyCanvasView(store: store, dashboardUI: dashboardUI)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}

private struct DashboardTaskBoardRouteView: View {
  let store: HarnessMonitorStore
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  @State private var taskBoardInboxSnapshot = TaskBoardInboxSnapshot(
    generatedAt: nil,
    isFromCache: true
  )

  private var visibleTaskBoardSessions: [SessionSummary] {
    let visible = store.visibleSessions
    return visible.isEmpty ? sessionCatalog.recentSessions : visible
  }

  private var taskBoardInboxSessionIDs: [String] {
    visibleTaskBoardSessions.map(\.sessionId)
  }

  var body: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: 24,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.dashboardScrollView,
      scrollSurfaceLabel: "Dashboard"
    ) {
      VStack(alignment: .leading, spacing: 24) {
        DashboardQuickActionsSection()
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
        SessionsBoardRecentSessionsSection(
          store: store,
          sessions: sessionCatalog.recentSessions
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task(id: taskBoardInboxSessionIDs) {
      await refreshVisibleTaskBoardInboxSnapshot()
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

private struct DashboardQuickActionsSection: View {
  var body: some View {
    Text("Dashboard")
      .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
      .accessibilityAddTraits(.isHeader)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
