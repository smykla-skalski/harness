import HarnessMonitorKit
import SwiftUI

private let contentWindowToolbarBackgroundVisibility: Visibility = .automatic
private let contentToolbarBackgroundMarker = "automatic"

public struct ContentView<CornerContent: View>: View {
  let store: HarnessMonitorStore
  let keyWindowObserver: KeyWindowObserver?
  let showsCornerAnimation: Bool
  let cornerAnimationContent: CornerContent
  let contentShell: HarnessMonitorStore.ContentShellSlice
  let contentChrome: HarnessMonitorStore.ContentChromeSlice
  let contentSession: HarnessMonitorStore.ContentSessionSlice
  let contentSessionDetail: HarnessMonitorStore.ContentSessionDetailSlice
  let contentDashboard: HarnessMonitorStore.ContentDashboardSlice
  private let toast: ToastSlice
  let auditBuildState: AuditBuildDisplayState?
  @State private var primaryContentPagingResponderRequest = 0
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var isStartupFocusParticipationEnabled = HarnessMonitorUITestEnvironment.isEnabled
  @Namespace private var primaryContentFocusScope
  private let toolbarGlassReproConfiguration = ToolbarGlassReproConfiguration.current

  private var appChromeAccessibilityValue: String {
    [
      "contentChrome=native",
      "interactiveRows=list",
      "controlGlass=native",
    ].joined(separator: ", ")
  }

  private var workspaceToolbarAccessibilityValue: String {
    let slice = store.supervisorToolbarSlice
    let severity = slice.maxSeverity?.rawValue ?? "none"
    let badge = slice.count > .zero ? "visible" : "hidden"
    return
      """
      count=\(slice.count) severity=\(severity) \
      tint=\(workspaceToolbarTint(for: slice.maxSeverity)) badge=\(badge)
      """
  }

  private var profilingAttributes: [String: String] {
    [
      "harness.view.surface":
        currentSurfaceLabel,
      "harness.view.column_visibility": columnVisibilityProfilingLabel,
    ]
  }

  private var currentSurfaceLabel: String {
    contentSessionDetail.presentedSessionDetail == nil ? "dashboard" : "cockpit"
  }

  private var currentSessionContentPrimaryFocusTarget: SessionContentPrimaryFocusTarget {
    if contentSessionDetail.presentedSessionDetail != nil {
      return .cockpit
    }
    if contentSession.selectedSessionSummary != nil {
      return .loading
    }
    return .dashboard
  }

  private var columnVisibilityProfilingLabel: String {
    if columnVisibility == .all {
      return "all"
    }
    if columnVisibility == .detailOnly {
      return "detailOnly"
    }
    // SwiftUI currently treats `.automatic` and `.doubleColumn` as the same
    // equality bucket on macOS. This window drives explicit visibility, so the
    // ambiguous branch represents the middle two-column state.
    return "doubleColumn"
  }

  @MainActor
  public init(
    store: HarnessMonitorStore,
    keyWindowObserver: KeyWindowObserver? = nil,
    showsCornerAnimation: Bool = true,
    @ViewBuilder cornerAnimationContent: () -> CornerContent
  ) {
    self.store = store
    self.keyWindowObserver = keyWindowObserver
    self.showsCornerAnimation = showsCornerAnimation
    self.cornerAnimationContent = cornerAnimationContent()
    self.contentShell = store.contentUI.shell
    self.contentChrome = store.contentUI.chrome
    self.contentSession = store.contentUI.session
    self.contentSessionDetail = store.contentUI.sessionDetail
    self.contentDashboard = store.contentUI.dashboard
    self.toast = store.toast
    self.auditBuildState = Self.resolveAuditBuildState()
  }

  public var body: some View {
    ViewBodySignposter.trace(Self.self, "ContentView", attributes: profilingAttributes) {
      #if HARNESS_FEATURE_LOTTIE
        baseContent
          .modifier(
            ContentCornerOverlayModifier(
              isPresented: showsCornerAnimation,
              cornerAnimationContent: cornerAnimationContent
            )
          )
      #else
        baseContent
      #endif
    }
  }

  private var baseContent: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebarColumn
    } detail: {
      detailColumn
    }
    .focusScope(primaryContentFocusScope)
    .navigationSplitViewStyle(.prominentDetail)
    .toolbarBackgroundVisibility(contentWindowToolbarBackgroundVisibility, for: .windowToolbar)
    .toolbar {
      contentToolbarItems
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.appChromeRoot)
    .overlay(contentAccessibilityOverlay)
    .overlay(alignment: .topTrailing) {
      ContentFloatingOverlay(
        toast: toast,
        auditBuildBadgeState: auditBuildBadgeState
      )
    }
    .background(contentBackground)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .coordinateSpace(name: "contentRoot")
    .modifier(
      HarnessMonitorConfirmationDialogModifier(
        store: store,
        shellUI: contentShell
      )
    )
    .modifier(
      HarnessMonitorSheetModifier(
        store: store,
        shellUI: contentShell
      )
    )
    .modifier(
      ContentAnnouncementsModifier(shellUI: contentShell)
    )
    .task(id: currentSurfaceLabel) {
      HarnessMonitorUITestTrace.record(
        component: "content.surface",
        event: "surface-changed",
        details: [
          "surface": currentSurfaceLabel,
          "selected_session_id": store.selectedSessionID ?? "nil",
        ]
      )
    }
  }

  private var contentToolbarModel: ContentWindowToolbarModel {
    ContentWindowToolbarModel(
      canNavigateBack: store.contentUI.toolbar.canNavigateBack,
      canNavigateForward: store.contentUI.toolbar.canNavigateForward,
      canCreateTask: store.areSelectedSessionActionsAvailable,
      isRefreshing: store.contentUI.toolbar.isRefreshing,
      sleepPreventionEnabled: store.contentUI.toolbar.sleepPreventionEnabled,
      mcpStatus: store.contentUI.toolbar.mcpStatus
    )
  }

  @ToolbarContentBuilder private var contentToolbarItems: some ToolbarContent {
    ContentWindowToolbarItems(
      store: store,
      model: contentToolbarModel
    )
  }

  @ViewBuilder private var contentAccessibilityOverlay: some View {
    ContentAccessibilityOverlayBridge(
      contentSession: contentSession,
      contentSessionDetail: contentSessionDetail,
      appChromeAccessibilityValue: appChromeAccessibilityValue,
      workspaceToolbarAccessibilityValue: workspaceToolbarAccessibilityValue,
      toolbarBackgroundMarker: contentToolbarBackgroundMarker,
      auditBuildAccessibilityValue: auditBuildAccessibilityValue
    )
  }

  private func workspaceToolbarTint(for severity: DecisionSeverity?) -> String {
    switch severity {
    case .none, .info:
      return "primary"
    case .warn, .needsUser:
      return "orange"
    case .critical:
      return "red"
    }
  }

  @ViewBuilder private var contentBackground: some View {
    if HarnessMonitorUITestEnvironment.isEnabled {
      EmptyView()
    } else {
      ContentSceneRestorationBridge(
        store: store,
        selection: store.selection,
        availableSessionCount: store.sessionIndex.searchResults.totalSessionCount,
        connectionState: store.connectionState,
        onRestorationResolved: enableStartupFocusParticipation
      )
    }
    ContentEscapeCommandBridge(
      store: store,
      toast: toast,
      contentSessionDetail: contentSessionDetail
    )
  }

  private var sidebarColumn: some View {
    SidebarView(
      store: store,
      controls: store.sessionIndex.controls,
      projection: store.sessionIndex.projection,
      searchResults: store.sessionIndex.searchResults,
      sidebarUI: store.sidebarUI,
      canPresentSearch: isStartupFocusParticipationEnabled
    )
    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
  }

  private var detailColumn: some View {
    ContentDetailColumn(
      store: store,
      keyWindowObserver: keyWindowObserver,
      toast: toast,
      selection: store.selection,
      contentChrome: contentChrome,
      contentSession: contentSession,
      contentSessionDetail: contentSessionDetail,
      dashboardUI: contentDashboard,
      primaryContentFocusScope: primaryContentFocusScope,
      primaryContentPagingResponderRequest: primaryContentPagingResponderRequest,
      primaryContentFocusTarget: currentSessionContentPrimaryFocusTarget,
      toolbarGlassReproConfiguration: toolbarGlassReproConfiguration
    )
  }

  private func enableStartupFocusParticipation() {
    guard !isStartupFocusParticipationEnabled else {
      return
    }
    isStartupFocusParticipationEnabled = true
  }
}

extension ContentView where CornerContent == EmptyView {
  @MainActor
  public init(
    store: HarnessMonitorStore,
    keyWindowObserver: KeyWindowObserver? = nil
  ) {
    self.init(
      store: store,
      keyWindowObserver: keyWindowObserver,
      showsCornerAnimation: false
    ) { EmptyView() }
  }
}
