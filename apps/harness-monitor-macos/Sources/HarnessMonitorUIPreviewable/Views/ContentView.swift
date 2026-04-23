import HarnessMonitorKit
import SwiftUI

private let contentWindowToolbarBackgroundVisibility: Visibility = .automatic
private let contentToolbarBackgroundMarker = "automatic"

public struct ContentView<CornerContent: View>: View {
  let store: HarnessMonitorStore
  let showsCornerAnimation: Bool
  let cornerAnimationContent: CornerContent
  let contentShell: HarnessMonitorStore.ContentShellSlice
  let contentChrome: HarnessMonitorStore.ContentChromeSlice
  let contentSession: HarnessMonitorStore.ContentSessionSlice
  let contentSessionDetail: HarnessMonitorStore.ContentSessionDetailSlice
  let contentDashboard: HarnessMonitorStore.ContentDashboardSlice
  private let toast: ToastSlice
  let auditBuildState: AuditBuildDisplayState?
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @AppStorage("showInspector")
  private var persistedShowInspector = true
  @AppStorage("inspectorColumnWidth")
  private var inspectorColumnWidth: Double = HarnessMonitorInspectorLayout.idealWidth
  @State private var showInspector = false
  @State private var isStartupFocusParticipationEnabled = HarnessMonitorUITestEnvironment.isEnabled
  @State private var shouldIgnoreNextInspectorMeasurement = false
  private let toolbarGlassReproConfiguration = ToolbarGlassReproConfiguration.current

  private var appChromeAccessibilityValue: String {
    [
      "contentChrome=native",
      "interactiveRows=list",
      "controlGlass=native",
    ].joined(separator: ", ")
  }

  private var supervisorBadgeAccessibilityValue: String {
    let slice = store.supervisorToolbarSlice
    let severity = slice.maxSeverity?.rawValue ?? "none"
    return
      "count=\(slice.count) severity=\(severity) tint=\(supervisorBadgeTint(for: slice.maxSeverity))"
  }

  private var profilingAttributes: [String: String] {
    [
      "harness.view.surface":
        contentSessionDetail.presentedSessionDetail == nil ? "dashboard" : "cockpit",
      "harness.view.column_visibility": columnVisibilityProfilingLabel,
      "harness.view.inspector_presented": showInspector ? "true" : "false",
    ]
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

  private var inspectorPresentationBinding: Binding<Bool> {
    Binding(
      get: { showInspector },
      set: { newValue in
        applyInspectorVisibilityChange(to: newValue, source: .framework)
      }
    )
  }

  @MainActor
  public init(
    store: HarnessMonitorStore,
    showsCornerAnimation: Bool = true,
    @ViewBuilder cornerAnimationContent: () -> CornerContent
  ) {
    self.store = store
    self.showsCornerAnimation = showsCornerAnimation
    self.cornerAnimationContent = cornerAnimationContent()
    self.contentShell = store.contentUI.shell
    self.contentChrome = store.contentUI.chrome
    self.contentSession = store.contentUI.session
    self.contentSessionDetail = store.contentUI.sessionDetail
    self.contentDashboard = store.contentUI.dashboard
    self.toast = store.toast
    self.auditBuildState = Self.resolveAuditBuildState()
    _showInspector = State(initialValue: ContentInspectorInitialPresentation.resolve())
  }

  public var body: some View {
    ViewBodySignposter.trace(Self.self, "ContentView", attributes: profilingAttributes) {
      baseContent
        .modifier(
          ContentCornerOverlayModifier(
            isPresented: showsCornerAnimation,
            cornerAnimationContent: cornerAnimationContent
          )
        )
    }
  }

  private var baseContent: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebarColumn
    } detail: {
      detailColumn
    }
    .navigationSplitViewStyle(.prominentDetail)
    .toolbarBackgroundVisibility(contentWindowToolbarBackgroundVisibility, for: .windowToolbar)
    .toolbar {
      contentToolbarItems
    }
    .onChange(of: persistedShowInspector) { _, newValue in
      applyInspectorVisibilityChange(to: newValue, source: .persistedPreference)
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
  }

  private var contentToolbarModel: ContentWindowToolbarModel {
    ContentWindowToolbarModel(
      canNavigateBack: store.contentUI.toolbar.canNavigateBack,
      canNavigateForward: store.contentUI.toolbar.canNavigateForward,
      canStartNewSession: store.connectionState == .online,
      isRefreshing: store.contentUI.toolbar.isRefreshing,
      sleepPreventionEnabled: store.contentUI.toolbar.sleepPreventionEnabled,
      showInspector: showInspector
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
      supervisorBadgeAccessibilityValue: supervisorBadgeAccessibilityValue,
      toolbarBackgroundMarker: contentToolbarBackgroundMarker,
      auditBuildAccessibilityValue: auditBuildAccessibilityValue
    )
  }

  private func supervisorBadgeTint(for severity: DecisionSeverity?) -> String {
    switch severity {
    case .none, .info:
      return "secondary"
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
      toast: toast,
      selection: store.selection,
      contentChrome: contentChrome,
      contentSession: contentSession,
      contentSessionDetail: contentSessionDetail,
      dashboardUI: contentDashboard,
      showInspector: showInspector,
      setInspectorVisibility: applyInspectorVisibilityChange,
      toolbarGlassReproConfiguration: toolbarGlassReproConfiguration
    )
    .inspector(isPresented: inspectorPresentationBinding) {
      inspectorColumn
    }
  }

  private var inspectorColumn: some View {
    InspectorColumnView(
      store: store,
      inspectorUI: store.inspectorUI
    )
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      updateInspectorWidth(width)
    }
    .inspectorColumnWidth(
      min: HarnessMonitorInspectorLayout.minWidth,
      ideal: inspectorColumnWidth,
      max: HarnessMonitorInspectorLayout.maxWidth
    )
  }

  private func updateInspectorWidth(_ width: CGFloat) {
    guard showInspector,
      width >= HarnessMonitorInspectorLayout.minWidth,
      width <= HarnessMonitorInspectorLayout.maxWidth
    else {
      return
    }
    if shouldIgnoreNextInspectorMeasurement {
      shouldIgnoreNextInspectorMeasurement = false
      return
    }
    guard abs(width - inspectorColumnWidth) > 1 else {
      return
    }
    inspectorColumnWidth = width
  }

  private func enableStartupFocusParticipation() {
    guard !isStartupFocusParticipationEnabled else {
      return
    }
    isStartupFocusParticipationEnabled = true
  }

  private func applyInspectorVisibilityChange(
    to newValue: Bool,
    source: ContentInspectorVisibilitySource
  ) {
    guard
      let change = ContentInspectorVisibilityPolicy.resolve(
        currentPresentation: showInspector,
        currentPersistedPreference: persistedShowInspector,
        nextPresentation: newValue,
        source: source
      )
    else {
      return
    }

    let isPresentingInspector = !showInspector && change.nextPresentation
    if isPresentingInspector {
      shouldIgnoreNextInspectorMeasurement = true
    }
    if showInspector != change.nextPresentation {
      showInspector = change.nextPresentation
    }
    if let persistedPreference = change.persistedPreference,
      persistedShowInspector != persistedPreference
    {
      persistedShowInspector = persistedPreference
    }
  }
}

extension ContentView where CornerContent == EmptyView {
  @MainActor
  public init(store: HarnessMonitorStore) {
    self.init(store: store, showsCornerAnimation: false) { EmptyView() }
  }
}
