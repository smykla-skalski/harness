import HarnessMonitorKit
import SwiftUI

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

struct DashboardBannerStack<Content: View>: View {
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

struct DashboardPerfRouteHook: ViewModifier {
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

enum DashboardWindowRoute: String, CaseIterable, Identifiable {
  case taskBoard
  case policyCanvas
  case notifications

  var id: String { rawValue }

  var title: String {
    switch self {
    case .taskBoard:
      "Board"
    case .policyCanvas:
      "Policy"
    case .notifications:
      "Notifications"
    }
  }

  var systemImage: String {
    switch self {
    case .taskBoard:
      "square.grid.2x2"
    case .policyCanvas:
      "point.3.connected.trianglepath.dotted"
    case .notifications:
      "bell.badge"
    }
  }
}

struct DashboardSidebar: View {
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

struct DashboardRouteContent: View {
  let route: DashboardWindowRoute
  let store: HarnessMonitorStore
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  @State private var notificationsHasBeenMounted = false
  @State private var policyCanvasHasBeenMounted = false

  private var isTaskBoardVisible: Bool { route == .taskBoard }
  private var isNotificationsVisible: Bool { route == .notifications }
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
    }
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

  private func refreshVisibleTaskBoardInboxSnapshot() async {
    let snapshot = await store.loadCachedTaskBoardInboxSnapshot(
      sessions: visibleTaskBoardSessions,
      limit: 120
    )
    guard !Task.isCancelled else { return }
    taskBoardInboxSnapshot = snapshot
  }
}
