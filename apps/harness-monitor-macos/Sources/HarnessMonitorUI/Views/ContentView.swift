import HarnessMonitorKit
import SwiftUI

enum ContentToolbarLayoutWidth {
  static let minimumWidth: CGFloat = 320
  static let defaultWidth: CGFloat = 1_000
}

public struct ContentView: View {
  let store: HarnessMonitorStore
  let cornerAnimationContent: (() -> AnyView)?
  let contentShell: HarnessMonitorStore.ContentShellSlice
  let contentToolbar: HarnessMonitorStore.ContentToolbarSlice
  let contentChrome: HarnessMonitorStore.ContentChromeSlice
  let contentSession: HarnessMonitorStore.ContentSessionSlice
  let contentDashboard: HarnessMonitorStore.ContentDashboardSlice
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @AppStorage("showInspector")
  private var persistedShowInspector = true
  @AppStorage("inspectorColumnWidth")
  private var inspectorColumnWidth: Double = HarnessMonitorInspectorLayout.idealWidth
  @SceneStorage("selectedSessionID")
  private var restoredSessionID: String?
  @State private var hasSeededSceneRestoration = false
  @State private var hasAppliedInitialInspectorVisibility = false
  @State private var hasCapturedInitialInspectorWidth = false
  @State private var showInspector = false
  @State private var detailColumnWidth: CGFloat = ContentToolbarLayoutWidth.defaultWidth
  @State private var toolbarBaselineLeadingInset: CGFloat = 260
  @State private var isLayoutAnimating = false
  private let toolbarGlassReproConfiguration = ToolbarGlassReproConfiguration.current

  private var windowTitle: String {
    contentShell.windowTitle
  }

  private var appChromeAccessibilityValue: String {
    [
      "contentChrome=native",
      "interactiveRows=list",
      "controlGlass=native",
    ].joined(separator: ", ")
  }

  private var toolbarChromeAccessibilityValue: String {
    [
      "toolbarTitle=native-window",
      "windowTitle=\(windowTitle)",
    ].joined(separator: ", ")
  }

  private var auditBuildState: AuditBuildDisplayState? {
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

  private var auditBuildAccessibilityValue: String? {
    auditBuildState?.accessibilityValue
  }

  private var toolbarLayoutWidth: CGFloat {
    max(detailColumnWidth, ContentToolbarLayoutWidth.minimumWidth)
  }

  private var toolbarCenterpieceDisplayMode: ToolbarCenterpieceDisplayMode {
    ToolbarCenterpieceDisplayMode.forDetailWidth(toolbarLayoutWidth)
  }

  private var activeToolbarBaselineLeadingInset: CGFloat {
    columnVisibility == .detailOnly ? 0 : toolbarBaselineLeadingInset
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
    self.contentDashboard = store.contentUI.dashboard
  }

  public var body: some View {
    if let cornerAnimationContent {
      baseContent
        .modifier(
          ContentCornerOverlayModifier(
            shellUI: contentShell,
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
    .navigationTitle(windowTitle)
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
    .onChange(of: restoredSessionID, initial: true) { _, newID in
      guard !hasSeededSceneRestoration else {
        return
      }
      guard contentShell.selectedSessionID == nil, let newID else {
        return
      }
      hasSeededSceneRestoration = true
      store.primeSessionSelection(newID)
    }
    .onChange(of: contentShell.selectedSessionID) { _, newID in
      if restoredSessionID != newID {
        restoredSessionID = newID
      }
      if newID != nil {
        hasSeededSceneRestoration = true
      }
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
      ZStack {
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.appChromeState,
          text: appChromeAccessibilityValue
        )
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.toolbarChromeState,
          text: toolbarChromeAccessibilityValue
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
    .overlay(alignment: .topTrailing) {
      if let auditBuildState, auditBuildState.showsVisibleBadge {
        AuditBuildBadge(state: auditBuildState)
          .padding(.top, HarnessMonitorTheme.spacingSM)
          .padding(.trailing, HarnessMonitorTheme.spacingLG)
      }
    }
    .modifier(
      OptionalToolbarBaselineOverlayModifier(
        isEnabled: !toolbarGlassReproConfiguration.disablesToolbarBaselineOverlay,
        leadingInset: activeToolbarBaselineLeadingInset
      )
    )
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
      onSidebarWidthChange: updateToolbarBaselineLeadingInset
    )
    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
  }

  private var detailColumn: some View {
    ContentDetailColumn(
      store: store,
      selection: store.selection,
      contentChrome: contentChrome,
      contentSession: contentSession,
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

  private func updateToolbarBaselineLeadingInset(_ width: CGFloat) {
    let nextValue = max((width / 4).rounded() * 4, 0)
    guard abs(nextValue - toolbarBaselineLeadingInset) >= 1 else {
      return
    }
    toolbarBaselineLeadingInset = nextValue
  }

  private func stringValue(
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

  private func bundleBuildProvenance() -> [String: String] {
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
