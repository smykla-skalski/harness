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
  private let auditBuildState: AuditBuildDisplayState?
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @AppStorage("showInspector")
  private var persistedShowInspector = true
  @AppStorage("inspectorColumnWidth")
  private var inspectorColumnWidth: Double = HarnessMonitorInspectorLayout.idealWidth
  @State private var hasAppliedInitialInspectorVisibility = false
  @State private var hasCapturedInitialInspectorWidth = false
  @State private var showInspector = false
  @State private var sidebarColumnWidth: CGFloat = 260
  @State private var detailColumnWidth: CGFloat = ContentToolbarLayoutWidth.defaultWidth
  @State private var isLayoutAnimating = false
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
    self.auditBuildState = Self.resolveAuditBuildState()
  }

  public var body: some View {
    if let cornerAnimationContent {
      baseContent
        .modifier(
          ContentCornerOverlayModifier(
            toolbarUI: contentToolbar,
            sessionUI: contentSession,
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
    .task {
      guard !hasAppliedInitialInspectorVisibility else {
        return
      }
      hasAppliedInitialInspectorVisibility = true
      await Task.yield()
      showInspector = persistedShowInspector
    }
    .onChange(of: persistedShowInspector) { _, newValue in
      guard hasAppliedInitialInspectorVisibility else {
        return
      }
      if showInspector != newValue {
        showInspector = newValue
      }
    }
    .onChange(of: showInspector) { _, newValue in
      if persistedShowInspector != newValue {
        persistedShowInspector = newValue
      }
      suppressLayoutGeometry()
    }
    .onChange(of: columnVisibility) { _, _ in
      suppressLayoutGeometry()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.appChromeRoot)
    .overlay {
      ContentAccessibilityOverlayBridge(
        contentToolbar: contentToolbar,
        contentSession: contentSession,
        contentSessionDetail: contentSessionDetail,
        toolbarCenterpieceDisplayMode: toolbarCenterpieceDisplayMode,
        appChromeAccessibilityValue: appChromeAccessibilityValue,
        auditBuildAccessibilityValue: auditBuildAccessibilityValue
      )
    }
    .overlay(alignment: .topTrailing) {
      if let auditBuildBadgeState, auditBuildBadgeState.showsVisibleBadge {
        AuditBuildBadge(state: auditBuildBadgeState)
          .padding(.top, HarnessMonitorTheme.spacingSM)
          .padding(.trailing, HarnessMonitorTheme.spacingLG)
      }
    }
    .background {
      ContentSceneRestorationBridge(
        store: store,
        selection: store.selection
      )
    }
    .modifier(
      OptionalToolbarBaselineOverlayModifier(
        isEnabled: !toolbarGlassReproConfiguration.disablesToolbarBaselineOverlay,
        leadingInset: columnVisibility == .detailOnly ? 0 : sidebarColumnWidth
      )
    )
    .suppressToolbarBaselineSeparator()
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

  private var sidebarColumn: some View {
    SidebarView(
      store: store,
      controls: store.sessionIndex.controls,
      projection: store.sessionIndex.projection,
      searchResults: store.sessionIndex.searchResults,
      sidebarUI: store.sidebarUI,
      sidebarVisible: columnVisibility != .detailOnly,
      onSidebarWidthChange: updateSidebarColumnWidth
    )
    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
  }

  private var detailColumn: some View {
    ContentDetailColumn(
      store: store,
      selection: store.selection,
      contentChrome: contentChrome,
      contentSession: contentSession,
      contentSessionDetail: contentSessionDetail,
      contentToolbar: contentToolbar,
      dashboardUI: contentDashboard,
      showInspector: $showInspector,
      toolbarGlassReproConfiguration: toolbarGlassReproConfiguration,
      isLayoutAnimating: isLayoutAnimating,
      detailColumnWidth: $detailColumnWidth
    )
    .inspector(isPresented: $showInspector) {
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
    isLayoutAnimating = true
    Task {
      try? await Task.sleep(for: .milliseconds(400))
      isLayoutAnimating = false
    }
  }

  private func updateInspectorWidth(_ width: CGFloat) {
    guard hasCapturedInitialInspectorWidth else {
      hasCapturedInitialInspectorWidth = true
      return
    }
    guard !isLayoutAnimating,
      showInspector,
      width >= HarnessMonitorInspectorLayout.minWidth,
      width <= HarnessMonitorInspectorLayout.maxWidth,
      abs(width - inspectorColumnWidth) > 1
    else {
      return
    }
    inspectorColumnWidth = width
  }

  private func updateSidebarColumnWidth(_ width: CGFloat) {
    guard abs(width - sidebarColumnWidth) > 1 else {
      return
    }
    sidebarColumnWidth = width
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

private struct ContentAccessibilityOverlayBridge: View {
  let contentToolbar: HarnessMonitorStore.ContentToolbarSlice
  let contentSession: HarnessMonitorStore.ContentSessionSlice
  let contentSessionDetail: HarnessMonitorStore.ContentSessionDetailSlice
  let toolbarCenterpieceDisplayMode: ToolbarCenterpieceDisplayMode
  let appChromeAccessibilityValue: String
  let auditBuildAccessibilityValue: String?

  var body: some View {
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
      ZStack {
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.appChromeState,
          text: appChromeAccessibilityValue
        )
        ContentToolbarChromeAccessibilityMarker(
          contentSession: contentSession,
          contentSessionDetail: contentSessionDetail
        )
        if let auditBuildAccessibilityValue {
          AccessibilityTextMarker(
            identifier: HarnessMonitorAccessibility.auditBuildState,
            text: auditBuildAccessibilityValue
          )
        }
        ContentToolbarAccessibilityMarker(toolbarUI: contentToolbar)
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.toolbarCenterpieceMode,
          text: toolbarCenterpieceDisplayMode.rawValue
        )
      }
    }
  }
}

private struct ContentSceneRestorationBridge: View {
  let store: HarnessMonitorStore
  let selection: HarnessMonitorStore.SelectionSlice
  @SceneStorage("selectedSessionID")
  private var restoredSessionID: String?
  @State private var hasSeededSceneRestoration = false

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .onAppear {
        seedRestorationIfNeeded(from: restoredSessionID)
      }
      .onChange(of: restoredSessionID) { _, newID in
        seedRestorationIfNeeded(from: newID)
      }
      .onChange(of: selection.selectedSessionID) { _, newID in
        if restoredSessionID != newID {
          restoredSessionID = newID
        }
        if newID != nil {
          hasSeededSceneRestoration = true
        }
      }
  }

  private func seedRestorationIfNeeded(from restoredSessionID: String?) {
    guard !hasSeededSceneRestoration else {
      return
    }
    guard selection.selectedSessionID == nil, let restoredSessionID else {
      return
    }
    hasSeededSceneRestoration = true
    store.primeSessionSelection(restoredSessionID)
  }
}

private struct ContentToolbarChromeAccessibilityMarker: View {
  let contentSession: HarnessMonitorStore.ContentSessionSlice
  let contentSessionDetail: HarnessMonitorStore.ContentSessionDetailSlice

  private var windowTitle: String {
    contentSessionDetail.selectedSessionDetail != nil
      || contentSession.selectedSessionSummary != nil
      ? "Cockpit" : "Dashboard"
  }

  var body: some View {
    AccessibilityTextMarker(
      identifier: HarnessMonitorAccessibility.toolbarChromeState,
      text: [
        "toolbarTitle=native-window",
        "windowTitle=\(windowTitle)",
      ].joined(separator: ", ")
    )
  }
}
