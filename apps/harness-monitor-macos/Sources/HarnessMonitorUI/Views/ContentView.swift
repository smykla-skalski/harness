import HarnessMonitorKit
import Observation
import SwiftUI

public struct ContentView: View {
  let store: HarnessMonitorStore
  let cornerAnimationContent: (() -> AnyView)?
  @Bindable var contentShell: HarnessMonitorStore.ContentShellSlice
  @Bindable var contentToolbar: HarnessMonitorStore.ContentToolbarSlice
  @Bindable var contentChrome: HarnessMonitorStore.ContentChromeSlice
  @Bindable var contentSession: HarnessMonitorStore.ContentSessionSlice
  @Bindable var contentDashboard: HarnessMonitorStore.ContentDashboardSlice
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
  @State private var detailColumnWidth: CGFloat = 980
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

  private var auditBuildAccessibilityValue: String? {
    guard HarnessMonitorUITestEnvironment.isEnabled else {
      return nil
    }

    let info = Bundle.main.infoDictionary ?? [:]
    let environment = ProcessInfo.processInfo.environment
    let provenance = bundleBuildProvenance()
    let commit =
      environment["HARNESS_MONITOR_AUDIT_GIT_COMMIT"]
      ?? provenance["HarnessMonitorBuildGitCommit"]
      ?? stringValue(in: info, key: "HarnessMonitorBuildGitCommit", fallback: "unknown")
    let dirty =
      environment["HARNESS_MONITOR_AUDIT_GIT_DIRTY"]
      ?? provenance["HarnessMonitorBuildGitDirty"]
      ?? stringValue(in: info, key: "HarnessMonitorBuildGitDirty", fallback: "unknown")
    let launchMode = environment["HARNESS_MONITOR_LAUNCH_MODE"] ?? "live"
    let perfScenario = environment["HARNESS_MONITOR_PERF_SCENARIO"] ?? "none"
    let previewScenario = environment["HARNESS_MONITOR_PREVIEW_SCENARIO"] ?? "default"

    return [
      "buildCommit=\(commit)",
      "buildDirty=\(dirty)",
      "launchMode=\(launchMode)",
      "perfScenario=\(perfScenario)",
      "previewScenario=\(previewScenario)",
    ].joined(separator: ", ")
  }

  private var detailAvailableWidth: CGFloat { max(detailColumnWidth, 320) }

  // Quantize resize-driven updates so the principal toolbar does not recompute
  // on every pixel delta while the split view divider is dragged.
  private var toolbarDetailWidth: CGFloat {
    (detailAvailableWidth / 10).rounded() * 10
  }

  private var toolbarCenterpieceDisplayMode: ToolbarCenterpieceDisplayMode {
    ToolbarCenterpieceDisplayMode.forDetailWidth(detailAvailableWidth)
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
        availableDetailWidth: toolbarDetailWidth
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
    .modifier(
      OptionalToolbarBaselineOverlayModifier(
        isEnabled: !toolbarGlassReproConfiguration.disablesToolbarBaselineOverlay
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
      sidebarUI: store.sidebarUI,
      sidebarVisible: columnVisibility != .detailOnly
    )
    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
    .toolbarBaselineFrame(.sidebar)
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

private struct ContentCornerOverlayModifier: ViewModifier {
  @Bindable var shellUI: HarnessMonitorStore.ContentShellSlice
  let cornerAnimationContent: () -> AnyView

  func body(content: Content) -> some View {
    content
      .modifier(
        HarnessCornerOverlayModifier(
          isPresented: shellUI.isSelectionLoading
            || shellUI.isExtensionsLoading
            || shellUI.isRefreshing
            || shellUI.connectionState == .connecting,
          configuration: .init(
            width: HarnessCornerAnimationDescriptor.dancingLlama.width,
            height: HarnessCornerAnimationDescriptor.dancingLlama.height,
            trailingPadding: HarnessCornerAnimationDescriptor.dancingLlama.trailingPadding,
            bottomPadding: HarnessCornerAnimationDescriptor.dancingLlama.bottomPadding,
            contentPadding: 0,
            appliesGlass: false,
            accessibilityLabel: HarnessCornerAnimationDescriptor.dancingLlama.accessibilityLabel,
            presentationDelay: .milliseconds(400)
          )
        ) {
          cornerAnimationContent()
        }
      )
  }
}

private struct ContentDetailColumn: View {
  let store: HarnessMonitorStore
  @Bindable var selection: HarnessMonitorStore.SelectionSlice
  @Bindable var contentChrome: HarnessMonitorStore.ContentChromeSlice
  @Bindable var contentSession: HarnessMonitorStore.ContentSessionSlice
  @Bindable var contentToolbar: HarnessMonitorStore.ContentToolbarSlice
  @Bindable var dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  @Binding var showInspector: Bool
  let toolbarGlassReproConfiguration: ToolbarGlassReproConfiguration
  let isLayoutAnimating: Bool
  @Binding var detailColumnWidth: CGFloat

  var body: some View {
    ZStack {
      if toolbarGlassReproConfiguration.disablesContentDetailChrome {
        sessionContent
      } else {
        ContentDetailChrome(
          persistenceError: contentChrome.persistenceError,
          sessionDataAvailability: contentChrome.sessionDataAvailability,
          sessionStatus: contentChrome.sessionStatus
        ) {
          sessionContent
        }
      }
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      guard !isLayoutAnimating,
            abs(width - detailColumnWidth) >= 1
      else {
        return
      }
      detailColumnWidth = width
    }
    .toolbar {
      ContentPrimaryToolbarItems(
        store: store,
        toolbarUI: contentToolbar,
        showInspector: $showInspector
      )
    }
    .onChange(of: selection.inspectorSelection) { _, newValue in
      if newValue != .none, !showInspector {
        showInspector = true
      }
    }
  }

  private var sessionContent: some View {
    SessionContentContainer(
      store: store,
      dashboardUI: dashboardUI,
      state: SessionContentState(
        detail: selection.matchedSelectedSession,
        summary: contentSession.selectedSessionSummary,
        timeline: selection.timeline,
        isSessionReadOnly: contentSession.isSessionReadOnly,
        isSessionActionInFlight: contentSession.isSessionActionInFlight,
        isSelectionLoading: contentSession.isSelectionLoading,
        isExtensionsLoading: contentSession.isExtensionsLoading,
        lastAction: contentSession.lastAction
      )
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.contentRoot).frame")
    .onKeyPress(.escape) {
      if selection.matchedSelectedSession != nil {
        store.inspectorSelection = .none
        return .handled
      }
      return .ignored
    }
  }
}

struct InspectorToolbarActions: ToolbarContent {
  let store: HarnessMonitorStore
  @Bindable var toolbarUI: HarnessMonitorStore.ContentToolbarSlice
  @Binding var showInspector: Bool
  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      RefreshToolbarButton(isRefreshing: toolbarUI.isRefreshing) {
        Task { await store.refresh() }
      }
        .help("Refresh sessions")
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItem(placement: .primaryAction) {
      Button { showInspector.toggle() } label: {
        Label(
          showInspector ? "Hide Inspector" : "Show Inspector",
          systemImage: "sidebar.trailing"
        )
      }
      .accessibilityLabel(showInspector ? "Hide Inspector" : "Show Inspector")
      .accessibilityIdentifier(HarnessMonitorAccessibility.inspectorToggleButton)
      .help(showInspector ? "Hide inspector" : "Show inspector")
    }
  }
}
