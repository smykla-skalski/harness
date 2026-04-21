import HarnessMonitorKit
import SwiftUI

private let contentWindowToolbarBackgroundVisibility: Visibility = .automatic
private let contentToolbarBackgroundMarker = "automatic"

public struct ContentView<CornerContent: View>: View {
  let store: HarnessMonitorStore
  let showsCornerAnimation: Bool
  let cornerAnimationContent: CornerContent
  let contentShell: HarnessMonitorStore.ContentShellSlice
  let contentToolbar: HarnessMonitorStore.ContentToolbarSlice
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
  @State private var isSidebarSearchPresented = false
  @State private var hasPendingSidebarSearchFocusRequest = false
  @FocusState private var isSidebarSearchFocused: Bool
  @State private var shouldIgnoreNextInspectorMeasurement = false
  @State private var detailColumnWidth: CGFloat = ContentToolbarLayoutWidth.defaultWidth
  @State private var stabilizedToolbarCenterpieceDisplayMode: ToolbarCenterpieceDisplayMode?
  @State private var pendingDetailColumnWidth: CGFloat?
  @State private var isLayoutAnimating = false
  @State private var layoutSuppressionTask: Task<Void, Never>?
  private let toolbarGlassReproConfiguration = ToolbarGlassReproConfiguration.current

  private var appChromeAccessibilityValue: String {
    [
      "contentChrome=native",
      "interactiveRows=list",
      "controlGlass=native",
    ].joined(separator: ", ")
  }
  private var profilingAttributes: [String: String] {
    [
      "harness.view.surface":
        contentSessionDetail.presentedSessionDetail == nil ? "dashboard" : "cockpit",
      "harness.view.column_visibility": "\(columnVisibility)",
      "harness.view.inspector_presented": showInspector ? "true" : "false",
      "harness.view.search_presented": isSidebarSearchPresented ? "true" : "false",
      "harness.view.connection_state": contentToolbar.connectionState.profilingLabel,
      "harness.view.status_message_count": "\(contentToolbar.statusMessages.count)",
      "harness.view.toolbar_mode": toolbarCenterpieceDisplayMode.rawValue,
      "harness.view.detail_width": "\(Int(toolbarLayoutWidth.rounded()))",
      "harness.view.layout_animating": isLayoutAnimating ? "true" : "false",
    ]
  }

  private var toolbarLayoutWidth: CGFloat {
    ContentToolbarLayoutWidth.normalized(detailColumnWidth)
  }

  private var sidebarSearchText: Binding<String> {
    Binding(
      get: { store.searchText },
      set: { store.searchText = $0 }
    )
  }

  private var toolbarCenterpieceDisplayMode: ToolbarCenterpieceDisplayMode {
    ToolbarCenterpieceDisplayMode.resolve(
      current: stabilizedToolbarCenterpieceDisplayMode,
      detailWidth: toolbarLayoutWidth
    )
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
    self.contentToolbar = store.contentUI.toolbar
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
    .searchable(
      text: sidebarSearchText,
      isPresented: $isSidebarSearchPresented,
      placement: .sidebar,
      prompt: Text("Search sessions, projects, leaders")
    )
    .searchFocused($isSidebarSearchFocused)
    .focusedSceneValue(\.harnessSidebarSearchFocusAction) {
      requestSidebarSearchPresentation()
    }
    .toolbarBackgroundVisibility(contentWindowToolbarBackgroundVisibility, for: .windowToolbar)
    .toolbar {
      contentToolbarItems
    }
    .onSubmit(of: .search) {
      submitSidebarSearch()
    }
    .onChange(of: isStartupFocusParticipationEnabled, initial: true) { _, isEnabled in
      guard isEnabled else {
        return
      }
      applyPendingSidebarSearchPresentationRequestIfNeeded(isEnabled: isEnabled)
    }
    .onChange(of: persistedShowInspector) { _, newValue in
      applyInspectorVisibilityChange(to: newValue, source: .persistedPreference)
    }
    .onChange(of: columnVisibility) { _, _ in
      suppressLayoutGeometry()
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

  @ToolbarContentBuilder private var contentToolbarItems: some ToolbarContent {
    ContentNavigationToolbarItems(
      store: store,
      toolbarUI: contentToolbar
    )
    ContentCenterpieceToolbarItems(
      store: store,
      toolbarUI: contentToolbar,
      displayMode: toolbarCenterpieceDisplayMode,
      availableDetailWidth: toolbarLayoutWidth
    )
  }

  @ViewBuilder private var contentAccessibilityOverlay: some View {
    ContentAccessibilityOverlayBridge(
      contentToolbar: contentToolbar,
      contentSession: contentSession,
      contentSessionDetail: contentSessionDetail,
      toolbarCenterpieceDisplayMode: toolbarCenterpieceDisplayMode,
      appChromeAccessibilityValue: appChromeAccessibilityValue,
      toolbarBackgroundMarker: contentToolbarBackgroundMarker,
      auditBuildAccessibilityValue: auditBuildAccessibilityValue
    )
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
      sidebarUI: store.sidebarUI
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
      contentToolbar: contentToolbar,
      dashboardUI: contentDashboard,
      showInspector: showInspector,
      setInspectorVisibility: applyInspectorVisibilityChange,
      toolbarGlassReproConfiguration: toolbarGlassReproConfiguration,
      onDetailColumnWidthChange: updateDetailColumnWidth
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

  private func suppressLayoutGeometry() {
    layoutSuppressionTask?.cancel()
    isLayoutAnimating = true
    layoutSuppressionTask = Task {
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else {
        return
      }
      if let pendingDetailColumnWidth,
        abs(pendingDetailColumnWidth - detailColumnWidth) >= 1
      {
        detailColumnWidth = pendingDetailColumnWidth
        stabilizedToolbarCenterpieceDisplayMode = ToolbarCenterpieceDisplayMode.resolve(
          current: stabilizedToolbarCenterpieceDisplayMode,
          detailWidth: pendingDetailColumnWidth
        )
      }
      self.pendingDetailColumnWidth = nil
      isLayoutAnimating = false
      layoutSuppressionTask = nil
    }
  }

  private func updateDetailColumnWidth(_ width: CGFloat) {
    let nextWidth = ContentToolbarLayoutWidth.normalized(width)
    if isLayoutAnimating {
      if abs(nextWidth - (pendingDetailColumnWidth ?? detailColumnWidth)) >= 1 {
        pendingDetailColumnWidth = nextWidth
      }
      return
    }
    guard abs(nextWidth - detailColumnWidth) >= 1 else {
      return
    }
    pendingDetailColumnWidth = nil
    detailColumnWidth = nextWidth
    stabilizedToolbarCenterpieceDisplayMode = ToolbarCenterpieceDisplayMode.resolve(
      current: stabilizedToolbarCenterpieceDisplayMode,
      detailWidth: nextWidth
    )
  }

  private func updateInspectorWidth(_ width: CGFloat) {
    guard !isLayoutAnimating,
      showInspector,
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

  func canPresentSidebarSearch() -> Bool { isStartupFocusParticipationEnabled }
  func schedulePendingSidebarSearchFocusRequest() { hasPendingSidebarSearchFocusRequest = true }
  func consumePendingSidebarSearchFocusRequest() -> Bool {
    defer { hasPendingSidebarSearchFocusRequest = false }
    return hasPendingSidebarSearchFocusRequest
  }
  func presentSidebarSearchNow() {
    (isSidebarSearchPresented, isSidebarSearchFocused) = (true, true)
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
    if change.shouldSuppressLayoutGeometry {
      suppressLayoutGeometry()
    }
  }

}

extension ContentView where CornerContent == EmptyView {
  @MainActor
  public init(store: HarnessMonitorStore) {
    self.init(store: store, showsCornerAnimation: false) { EmptyView() }
  }
}
