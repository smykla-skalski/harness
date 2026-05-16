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

  private func makeProfilingAttributes(
    route: DashboardWindowRoute,
    columnVisibility: NavigationSplitViewVisibility
  ) -> [String: String] {
    [
      "harness.view.surface": "dashboard",
      "harness.view.column_visibility": SessionColumnVisibilityCodec.encode(columnVisibility),
      "harness.view.selected_route": route.rawValue,
    ]
  }

  private func dashboardStatusSummaryModel(
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
          selectedRoute: selectedRouteBinding,
          statusModel: dashboardStatusSummaryModel(route: route)
        )
      } detail: {
        DashboardBannerStack(store: store) {
          DashboardRouteContent(
            route: route,
            store: store,
            dashboardUI: dashboardUI,
            sessionCatalog: sessionCatalog
          )
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardWindowRoot)
      .toolbar {
        DashboardWindowToolbar(
          store: store,
          showsQuickActions: selectedRoute == .taskBoard,
          sleepPreventionPresentation: SleepPreventionToolbarPresentation(
            isEnabled: store.contentUI.toolbar.sleepPreventionEnabled
          )
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
      .modifier(DashboardPerfRouteHook(selectedRouteBinding: selectedRouteBinding))
    }
  }
}

private struct DashboardBannerStackModel: Equatable {
  let showsContentChrome: Bool
  let observedDaemonWireVersion: Int?

  init(
    contentChrome: ContentChromeBannerModel,
    observedDaemonWireVersion: Int?
  ) {
    showsContentChrome = contentChrome.isPresented
    self.observedDaemonWireVersion = observedDaemonWireVersion
  }

  var showsDaemonWireVersionSkew: Bool {
    guard let observedDaemonWireVersion else { return false }
    return observedDaemonWireVersion < HarnessMonitorStore.minimumDaemonWireVersion
  }

  var isPresented: Bool {
    showsContentChrome || showsDaemonWireVersionSkew
  }
}

private struct DashboardBannerStack<Content: View>: View {
  let store: HarnessMonitorStore
  private let content: Content

  init(store: HarnessMonitorStore, @ViewBuilder content: () -> Content) {
    self.store = store
    self.content = content()
  }

  private var chrome: HarnessMonitorStore.ContentChromeSlice {
    store.contentUI.chrome
  }

  private var chromeBannerModel: ContentChromeBannerModel {
    ContentChromeBannerModel(
      persistenceError: chrome.persistenceError,
      sessionDataAvailability: chrome.sessionDataAvailability,
      mcpStatus: chrome.mcpStatus,
      hasACPBridgeBanner: chrome.acpBridgeBanner != nil
    )
  }

  private var model: DashboardBannerStackModel {
    DashboardBannerStackModel(
      contentChrome: chromeBannerModel,
      observedDaemonWireVersion: store.health?.wireVersion
    )
  }

  var body: some View {
    WindowBannerChrome(
      windowID: HarnessMonitorWindowID.dashboard,
      isPresented: model.isPresented
    ) {
      content
        .harnessMonitorBackgroundExtensionEffect()
    } banners: {
      topChrome
    }
  }

  @ViewBuilder private var topChrome: some View {
    VStack(spacing: 0) {
      if let observed = model.observedDaemonWireVersion, model.showsDaemonWireVersionSkew {
        DaemonWireVersionSkewBanner(
          observed: observed,
          expected: HarnessMonitorStore.minimumDaemonWireVersion
        )
        chromeDivider(tint: HarnessMonitorTheme.danger)
      }
      ContentChromeBannerStack(
        store: store,
        contentChrome: chrome,
        windowID: HarnessMonitorWindowID.dashboard
      )
    }
  }

  private func chromeDivider(tint: Color) -> some View {
    WindowBannerDivider(tint: tint)
  }
}

private struct DashboardPerfRouteHook: ViewModifier {
  let selectedRouteBinding: Binding<DashboardWindowRoute>
  private let isActive = HarnessMonitorPerfDashboardRouteBus.isActive()

  func body(content: Content) -> some View {
    if isActive {
      content
        .onReceive(
          NotificationCenter.default.publisher(
            for: HarnessMonitorPerfDashboardRouteBus.routeChange
          )
        ) { note in
          guard
            let raw = note.userInfo?[HarnessMonitorPerfDashboardRouteBus.routeRawKey] as? String,
            let next = DashboardWindowRoute(rawValue: raw)
          else { return }
          guard selectedRouteBinding.wrappedValue != next else { return }
          withAnimation(.easeInOut(duration: 0.15)) {
            selectedRouteBinding.wrappedValue = next
          }
          HarnessMonitorPerfDashboardRouteBus.recordAccepted(raw: raw)
        }
    } else {
      content
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
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.dashboardWindowRoute(route.rawValue)
            )
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
  /// Tracks whether the PolicyCanvas surface has been mounted at least once in
  /// this window's lifetime. The first route flip to `.policyCanvas` is a
  /// ~900ms hang in r18 because SwiftUI tears down the TaskBoard tree and
  /// builds PolicyCanvas's full surface (top bar + viewport + inspector +
  /// view-model bootstrap) synchronously on the main thread. Once mounted,
  /// keep PolicyCanvas alive behind an opacity-0 mask so subsequent route
  /// flips back to it are an opacity toggle, not a remount. TaskBoard stays
  /// the eager surface because users land on it; PolicyCanvas only mounts on
  /// first visit and stays warm thereafter.
  @State private var policyCanvasHasBeenMounted = false

  private var isTaskBoardVisible: Bool { route == .taskBoard }
  private var isPolicyCanvasVisible: Bool { route == .policyCanvas }

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

      if policyCanvasHasBeenMounted || isPolicyCanvasVisible {
        PolicyCanvasView(store: store, dashboardUI: dashboardUI)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .opacity(isPolicyCanvasVisible ? 1 : 0)
          .allowsHitTesting(isPolicyCanvasVisible)
          .accessibilityHidden(!isPolicyCanvasVisible)
          .onAppear {
            // First mount paid the 900ms cost; mark the surface persistent so
            // future flips skip the remount. Setting the flag is idempotent.
            policyCanvasHasBeenMounted = true
          }
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
  @State private var perfScrollPosition = ScrollPosition()
  private let perfScrollHookEnabled = HarnessMonitorPerfDashboardScrollBus.isActive()
  private let detailRowHorizontalPadding: CGFloat = 24

  private var visibleTaskBoardSessions: [SessionSummary] {
    let visible = store.visibleSessions
    return visible.isEmpty ? sessionCatalog.recentSessions : visible
  }

  private var taskBoardInboxSessionIDs: [String] {
    visibleTaskBoardSessions.map(\.sessionId)
  }

  var body: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: 0,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.dashboardScrollView,
      scrollSurfaceLabel: "Dashboard",
      scrollPosition: perfScrollHookEnabled ? $perfScrollPosition : nil
    ) {
      VStack(alignment: .leading, spacing: 24) {
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
        SessionsBoardRecentSessionsSection(store: store, sessions: sessionCatalog.recentSessions)
          .padding(.horizontal, detailRowHorizontalPadding)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
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
      // Reassigning the whole value (not the mutating method) is the pattern
      // PolicyCanvas uses — it writes through @State reliably even when the
      // binding is consumed inside a wrapped view tree.
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

  private func refreshVisibleTaskBoardInboxSnapshot() async {
    let snapshot = await store.loadCachedTaskBoardInboxSnapshot(
      sessions: visibleTaskBoardSessions,
      limit: 120
    )
    guard !Task.isCancelled else { return }
    taskBoardInboxSnapshot = snapshot
  }
}
