import HarnessMonitorKit
import SwiftUI

enum ContentToolbarLayoutWidth {
  static let minimumWidth: CGFloat = 320
  static let defaultWidth: CGFloat = 1_000
  // The toolbar only changes meaningfully at coarse width buckets. Snapping
  // more aggressively avoids feeding detail-column layout jitter back into the
  // split-view shell during cockpit transitions.
  static let measurementQuantum: CGFloat = 32

  static func normalized(_ width: CGFloat) -> CGFloat {
    let clampedWidth = max(width, minimumWidth)
    return (clampedWidth / measurementQuantum).rounded() * measurementQuantum
  }
}

public struct ContentView: View {
  let store: HarnessMonitorStore
  let cornerAnimationContent: (() -> AnyView)?
  let contentShell: HarnessMonitorStore.ContentShellSlice
  let contentToolbar: HarnessMonitorStore.ContentToolbarSlice
  let contentChrome: HarnessMonitorStore.ContentChromeSlice
  let contentSession: HarnessMonitorStore.ContentSessionSlice
  let contentSessionDetail: HarnessMonitorStore.ContentSessionDetailSlice
  let contentDashboard: HarnessMonitorStore.ContentDashboardSlice
  private let toast: ToastSlice
  private let auditBuildState: AuditBuildDisplayState?
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @AppStorage("showInspector")
  private var persistedShowInspector = true
  @AppStorage("inspectorColumnWidth")
  private var inspectorColumnWidth: Double = HarnessMonitorInspectorLayout.idealWidth
  @State private var showInspector = false
  @State private var hasHydratedInspectorVisibility = false
  @State private var isStartupFocusParticipationEnabled = false
  @State private var shouldIgnoreNextInspectorMeasurement = false
  @State private var detailColumnWidth: CGFloat = ContentToolbarLayoutWidth.defaultWidth
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

  private var auditBuildAccessibilityValue: String? {
    auditBuildState?.accessibilityValue
  }

  private var auditBuildBadgeState: AuditBuildDisplayState? {
    guard let auditBuildState else {
      return nil
    }
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled
      || auditBuildState.status == "mismatch"
    {
      return auditBuildState
    }
    return nil
  }

  private var toolbarLayoutWidth: CGFloat {
    ContentToolbarLayoutWidth.normalized(detailColumnWidth)
  }

  private var toolbarCenterpieceDisplayMode: ToolbarCenterpieceDisplayMode {
    ToolbarCenterpieceDisplayMode.forDetailWidth(toolbarLayoutWidth)
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
    cornerAnimationContent: (() -> AnyView)? = nil
  ) {
    self.store = store
    self.cornerAnimationContent = cornerAnimationContent
    self.contentShell = store.contentUI.shell
    self.contentToolbar = store.contentUI.toolbar
    self.contentChrome = store.contentUI.chrome
    self.contentSession = store.contentUI.session
    self.contentSessionDetail = store.contentUI.sessionDetail
    self.contentDashboard = store.contentUI.dashboard
    self.toast = store.toast
    self.auditBuildState = Self.resolveAuditBuildState()
  }

  public var body: some View {
    if let cornerAnimationContent {
      baseContent
        .modifier(
          ContentCornerOverlayModifier(
            toolbarUI: contentToolbar,
            cornerAnimationContent: cornerAnimationContent
          )
        )
    } else {
      baseContent
    }
  }

  private var baseContent: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebarColumn
    } detail: {
      detailColumn
    }
    .navigationSplitViewStyle(.prominentDetail)
    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    .containerBackground(.windowBackground, for: .window)
    .toolbar {
      contentToolbarItems
    }
    .onChange(of: isStartupFocusParticipationEnabled, initial: true) { _, isEnabled in
      guard isEnabled else {
        return
      }
      hydrateInspectorVisibilityIfNeeded()
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
      sidebarUI: store.sidebarUI,
      sidebarVisible: columnVisibility != .detailOnly,
      focusParticipationEnabled: isStartupFocusParticipationEnabled
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

  private func hydrateInspectorVisibilityIfNeeded() {
    guard !hasHydratedInspectorVisibility else {
      return
    }
    hasHydratedInspectorVisibility = true
    applyInspectorVisibilityChange(
      to: persistedShowInspector,
      source: .persistedPreference
    )
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

  private static func resolveAuditBuildState() -> AuditBuildDisplayState? {
    guard HarnessMonitorUITestEnvironment.isEnabled else {
      return nil
    }

    let info = Bundle.main.infoDictionary ?? [:]
    let environment = ProcessInfo.processInfo.environment
    let provenance = bundleBuildProvenance()

    return AuditBuildDisplayState(
      auditRunID: environment["HARNESS_MONITOR_AUDIT_RUN_ID"] ?? "none",
      auditLabel: environment["HARNESS_MONITOR_AUDIT_LABEL"] ?? "none",
      launchMode: environment["HARNESS_MONITOR_LAUNCH_MODE"] ?? "live",
      perfScenario: environment["HARNESS_MONITOR_PERF_SCENARIO"] ?? "none",
      previewScenario: environment["HARNESS_MONITOR_PREVIEW_SCENARIO"] ?? "default",
      buildCommit: provenance["HarnessMonitorBuildGitCommit"]
        ?? stringValue(in: info, key: "HarnessMonitorBuildGitCommit", fallback: "unknown"),
      buildDirty: provenance["HarnessMonitorBuildGitDirty"]
        ?? stringValue(in: info, key: "HarnessMonitorBuildGitDirty", fallback: "unknown"),
      buildFingerprint: provenance["HarnessMonitorBuildWorkspaceFingerprint"]
        ?? stringValue(
          in: info,
          key: "HarnessMonitorBuildWorkspaceFingerprint",
          fallback: "unknown"
        ),
      buildStartedAtUTC: provenance["HarnessMonitorBuildStartedAtUTC"]
        ?? stringValue(
          in: info,
          key: "HarnessMonitorBuildStartedAtUTC",
          fallback: "unknown"
        ),
      expectedCommit: environment["HARNESS_MONITOR_AUDIT_GIT_COMMIT"],
      expectedDirty: environment["HARNESS_MONITOR_AUDIT_GIT_DIRTY"],
      expectedFingerprint: environment["HARNESS_MONITOR_AUDIT_WORKSPACE_FINGERPRINT"],
      expectedBuildStartedAtUTC: environment["HARNESS_MONITOR_AUDIT_BUILD_STARTED_AT_UTC"]
    )
  }

  private static func stringValue(
    in infoDictionary: [String: Any],
    key: String,
    fallback: String
  ) -> String {
    guard let value = infoDictionary[key] as? String else {
      return fallback
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  private static func bundleBuildProvenance() -> [String: String] {
    guard
      let url = Bundle.main.url(
        forResource: "HarnessMonitorBuildProvenance",
        withExtension: "plist"
      ),
      let dictionary = NSDictionary(contentsOf: url) as? [String: Any]
    else {
      return [:]
    }

    return dictionary.compactMapValues { value in
      guard let stringValue = value as? String else {
        return nil
      }
      let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }
}
