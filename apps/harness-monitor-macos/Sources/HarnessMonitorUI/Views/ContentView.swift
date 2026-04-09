import HarnessMonitorKit
import Observation
import SwiftUI

public struct ContentView: View {
  let store: HarnessMonitorStore
  let showsCornerAnimation: Bool
  let cornerAnimationContent: (() -> AnyView)?
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
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
  @State private var showLlama = false
  @State private var detailColumnWidth: CGFloat = 980
  @State private var isInspectorAnimating = false
  private let toolbarGlassReproConfiguration = ToolbarGlassReproConfiguration.current

  private var windowTitle: String {
    contentUI.windowTitle
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
    let commit =
      environment["HARNESS_MONITOR_AUDIT_GIT_COMMIT"]
      ?? stringValue(in: info, key: "HarnessMonitorBuildGitCommit", fallback: "unknown")
    let dirty =
      environment["HARNESS_MONITOR_AUDIT_GIT_DIRTY"]
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
    showsCornerAnimation: Bool = false,
    cornerAnimationContent: (() -> AnyView)? = nil
  ) {
    self.store = store
    self.showsCornerAnimation = showsCornerAnimation
    self.cornerAnimationContent = cornerAnimationContent
    self.contentUI = store.contentUI
  }

  public var body: some View {
    if let cornerAnimationContent {
      baseContent
        .modifier(
          HarnessCornerOverlayModifier(
            isPresented: showLlama
              || contentUI.isSelectionLoading
              || contentUI.isExtensionsLoading
              || contentUI.isRefreshing
              || contentUI.connectionState == .connecting,
            configuration: .init(
              width: HarnessCornerAnimationDescriptor.dancingLlama.width,
              height: HarnessCornerAnimationDescriptor.dancingLlama.height,
              trailingPadding: HarnessCornerAnimationDescriptor.dancingLlama.trailingPadding,
              bottomPadding: HarnessCornerAnimationDescriptor.dancingLlama.bottomPadding,
              contentPadding: 0,
              appliesGlass: false,
              accessibilityLabel: HarnessCornerAnimationDescriptor.dancingLlama.accessibilityLabel,
              presentationDelay: showLlama ? nil : .milliseconds(400)
            )
          ) {
            cornerAnimationContent()
          }
        )
    } else {
      baseContent
    }
  }

  private var baseContent: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      SidebarView(
        store: store,
        catalog: store.sessionIndex.catalog,
        projection: store.sessionIndex.projection,
        sidebarUI: store.sidebarUI
      )
      .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
      .toolbarBaselineFrame(.sidebar)
    } detail: {
      ContentDetailColumn(
        store: store,
        selection: store.selection,
        contentUI: contentUI,
        showInspector: $showInspector,
        toolbarGlassReproConfiguration: toolbarGlassReproConfiguration,
        detailWidthChanged: { width in
          guard !isInspectorAnimating,
                abs(width - detailColumnWidth) >= 1
          else {
            return
          }
          detailColumnWidth = width
        }
      )
      .inspector(isPresented: $showInspector) {
        InspectorColumnView(
          store: store,
          inspectorUI: store.inspectorUI
        )
          .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
          } action: { width in
            guard hasCapturedInitialInspectorWidth else {
              hasCapturedInitialInspectorWidth = true
              return
            }
            guard !isInspectorAnimating,
                  showInspector,
                  width >= HarnessMonitorInspectorLayout.minWidth,
                  width <= HarnessMonitorInspectorLayout.maxWidth,
                  abs(width - inspectorColumnWidth) > 1
            else {
              return
            }
            inspectorColumnWidth = width
          }
          .inspectorColumnWidth(
            min: HarnessMonitorInspectorLayout.minWidth,
            ideal: inspectorColumnWidth,
            max: HarnessMonitorInspectorLayout.maxWidth
          )
      }
    }
    .navigationSplitViewStyle(.prominentDetail)
    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    .containerBackground(.windowBackground, for: .window)
    .navigationTitle(windowTitle)
    .toolbar {
      ContentNavigationToolbarItems(
        contentUI: contentUI,
        navigateBack: navigateBack,
        navigateForward: navigateForward
      )
      ContentCenterpieceToolbarItems(
        contentUI: contentUI,
        displayMode: toolbarCenterpieceDisplayMode,
        availableDetailWidth: toolbarDetailWidth,
        showsLlamaToggle: showsCornerAnimation,
        showLlama: $showLlama,
        toggleSleepPrevention: toggleSleepPrevention
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
      guard contentUI.selectedSessionID == nil, let newID else {
        return
      }
      hasSeededSceneRestoration = true
      store.primeSessionSelection(newID)
    }
    .onChange(of: contentUI.selectedSessionID) { _, newID in
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
      isInspectorAnimating = true
      Task {
        try? await Task.sleep(for: .milliseconds(400))
        isInspectorAnimating = false
      }
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
        ContentToolbarAccessibilityMarker(contentUI: contentUI)
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
        pendingConfirmation: contentUI.pendingConfirmation
      )
    )
    .modifier(
      HarnessMonitorSheetModifier(
        store: store,
        presentedSheet: contentUI.presentedSheet
      )
    )
    .modifier(
      ContentAnnouncementsModifier(
        connectionState: contentUI.connectionState,
        lastAction: contentUI.lastAction
      )
    )
  }

  func navigateBack() {
    Task { await store.navigateBack() }
  }

  func navigateForward() {
    Task { await store.navigateForward() }
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

  func toggleSleepPrevention() {
    store.sleepPreventionEnabled.toggle()
  }
}

private struct ContentDetailColumn: View {
  let store: HarnessMonitorStore
  @Bindable var selection: HarnessMonitorStore.SelectionSlice
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
  @Binding var showInspector: Bool
  let toolbarGlassReproConfiguration: ToolbarGlassReproConfiguration
  let detailWidthChanged: (CGFloat) -> Void

  var body: some View {
    ZStack {
      if toolbarGlassReproConfiguration.disablesContentDetailChrome {
        sessionContent
      } else {
        ContentDetailChrome(
          persistenceError: contentUI.persistenceError,
          sessionDataAvailability: contentUI.sessionDataAvailability,
          sessionStatus: contentUI.sessionStatus
        ) {
          sessionContent
        }
      }
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      detailWidthChanged(width)
    }
    .toolbar {
      ContentPrimaryToolbarItems(
        store: store,
        contentUI: contentUI,
        showInspector: $showInspector
      )
    }
  }

  private var sessionContent: some View {
    SessionContentContainer(
      store: store,
      state: SessionContentState(
        detail: selection.matchedSelectedSession,
        summary: contentUI.selectedSessionSummary,
        timeline: selection.timeline,
        isSessionReadOnly: contentUI.isSessionReadOnly,
        isSessionActionInFlight: contentUI.isSessionActionInFlight,
        isSelectionLoading: contentUI.isSelectionLoading,
        isExtensionsLoading: contentUI.isExtensionsLoading,
        lastAction: contentUI.lastAction
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
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
  @Binding var showInspector: Bool
  @Environment(\.openWindow)
  private var openWindow

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      RefreshToolbarButton(isRefreshing: contentUI.isRefreshing) {
        Task { await store.refresh() }
      }
        .help("Refresh sessions")

      Button { openWindow(id: HarnessMonitorWindowID.preferences) } label: {
        Label("Settings", systemImage: "gearshape")
      }
      .help("Open settings")
      .accessibilityIdentifier(HarnessMonitorAccessibility.daemonPreferencesButton)
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
