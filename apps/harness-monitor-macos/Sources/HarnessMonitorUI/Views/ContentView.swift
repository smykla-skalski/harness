import HarnessMonitorKit
import Observation
import SwiftUI

private enum HarnessMonitorInspectorLayout {
  static let minWidth: CGFloat = 320
  static let idealWidth: CGFloat = 420
  static let maxWidth: CGFloat = 760
}

public struct ContentView: View {
  let store: HarnessMonitorStore
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
  @Environment(\.openWindow)
  private var openWindow
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var toolbarCenterpieceDisplayMode: ToolbarCenterpieceDisplayMode = .standard
  @AppStorage("showInspector")
  private var showInspector = true
  @AppStorage("inspectorColumnWidth")
  private var inspectorColumnWidth: Double = HarnessMonitorInspectorLayout.idealWidth
  @SceneStorage("selectedSessionID")
  private var restoredSessionID: String?
  @State private var showLlama = false
  private let toolbarGlassReproConfiguration = ToolbarGlassReproConfiguration.current

  private var windowTitle: String {
    contentUI.windowTitle
  }

  private var appChromeAccessibilityValue: String {
    [
      "contentChrome=native",
      "interactiveRows=button",
      "controlGlass=native",
    ].joined(separator: ", ")
  }

  private var toolbarChromeAccessibilityValue: String {
    [
      "toolbarTitle=native-window",
      "windowTitle=\(windowTitle)",
    ].joined(separator: ", ")
  }

  public init(store: HarnessMonitorStore) {
    self.store = store
    self.contentUI = store.contentUI
  }

  public var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      SidebarView(
        store: store,
        sessionIndex: store.sessionIndex,
        sidebarUI: store.sidebarUI
      )
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        .toolbarBaselineFrame(.sidebar)
    } detail: {
      ContentDetailColumn(
        store: store,
        contentUI: contentUI,
        showInspector: $showInspector,
        inspectorColumnWidth: $inspectorColumnWidth,
        showLlama: $showLlama,
        toolbarGlassReproConfiguration: toolbarGlassReproConfiguration,
        openPreferences: openPreferences,
        refresh: refresh,
        toggleSleepPrevention: toggleSleepPrevention
      )
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
        displayMode: toolbarCenterpieceDisplayMode
      )
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { windowWidth in
      let nextMode = ToolbarCenterpieceDisplayMode.forWindowWidth(windowWidth)
      guard nextMode != toolbarCenterpieceDisplayMode else {
        return
      }
      toolbarCenterpieceDisplayMode = nextMode
    }
    .onAppear {
      if let restoredSessionID, contentUI.selectedSessionID == nil {
        Task { await store.selectSession(restoredSessionID) }
      }
    }
    .onChange(of: contentUI.selectedSessionID) { _, newID in
      restoredSessionID = newID
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
    .harnessCornerAnimation(
      .dancingLlama,
      isPresented: showLlama
        || contentUI.isSelectionLoading
        || contentUI.isExtensionsLoading
        || contentUI.isRefreshing
        || contentUI.connectionState == .connecting,
      presentationDelay: showLlama ? nil : .milliseconds(400)
    )
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

  private func openPreferences() {
    openWindow(id: HarnessMonitorWindowID.preferences)
  }

  func navigateBack() {
    Task { await store.navigateBack() }
  }

  func navigateForward() {
    Task { await store.navigateForward() }
  }

  func refresh() {
    Task { await store.refresh() }
  }

  func toggleSleepPrevention() {
    store.sleepPreventionEnabled.toggle()
  }
}

private struct ContentDetailColumn: View {
  let store: HarnessMonitorStore
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
  @Binding var showInspector: Bool
  @Binding var inspectorColumnWidth: Double
  @Binding var showLlama: Bool
  let toolbarGlassReproConfiguration: ToolbarGlassReproConfiguration
  let openPreferences: () -> Void
  let refresh: () -> Void
  let toggleSleepPrevention: () -> Void

  init(
    store: HarnessMonitorStore,
    contentUI: HarnessMonitorStore.ContentUISlice,
    showInspector: Binding<Bool>,
    inspectorColumnWidth: Binding<Double>,
    showLlama: Binding<Bool>,
    toolbarGlassReproConfiguration: ToolbarGlassReproConfiguration,
    openPreferences: @escaping () -> Void,
    refresh: @escaping () -> Void,
    toggleSleepPrevention: @escaping () -> Void
  ) {
    self.store = store
    self.contentUI = contentUI
    self._showInspector = showInspector
    self._inspectorColumnWidth = inspectorColumnWidth
    self._showLlama = showLlama
    self.toolbarGlassReproConfiguration = toolbarGlassReproConfiguration
    self.openPreferences = openPreferences
    self.refresh = refresh
    self.toggleSleepPrevention = toggleSleepPrevention
  }

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
    .inspector(isPresented: $showInspector) {
      InspectorColumnView(store: store, inspectorUI: store.inspectorUI)
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.width
        } action: { width in
          guard width >= HarnessMonitorInspectorLayout.minWidth,
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
    .toolbar {
      ContentPrimaryToolbarItems(
        contentUI: contentUI,
        showLlama: $showLlama,
        showInspector: $showInspector,
        openPreferences: openPreferences,
        refresh: refresh,
        toggleSleepPrevention: toggleSleepPrevention
      )
    }
  }

  private var sessionContent: some View {
    SessionContentContainer(
      store: store,
      state: SessionContentState(
        detail: contentUI.selectedDetail,
        summary: contentUI.selectedSessionSummary,
        timeline: contentUI.timeline,
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
      if store.inspectorUI.actionContext != nil {
        store.inspectorSelection = .none
        return .handled
      }
      return .ignored
    }
  }
}

private struct ContentNavigationToolbarItems: ToolbarContent {
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
  let navigateBack: () -> Void
  let navigateForward: () -> Void

  init(
    contentUI: HarnessMonitorStore.ContentUISlice,
    navigateBack: @escaping () -> Void,
    navigateForward: @escaping () -> Void
  ) {
    self.contentUI = contentUI
    self.navigateBack = navigateBack
    self.navigateForward = navigateForward
  }

  var body: some ToolbarContent {
    ContentNavigationToolbar(
      canNavigateBack: contentUI.canNavigateBack,
      canNavigateForward: contentUI.canNavigateForward,
      navigateBack: navigateBack,
      navigateForward: navigateForward
    )
  }
}

private struct ContentCenterpieceToolbarItems: ToolbarContent {
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
  let displayMode: ToolbarCenterpieceDisplayMode

  init(
    contentUI: HarnessMonitorStore.ContentUISlice,
    displayMode: ToolbarCenterpieceDisplayMode
  ) {
    self.contentUI = contentUI
    self.displayMode = displayMode
  }

  var body: some ToolbarContent {
    ContentCenterpieceToolbar(
      model: ToolbarCenterpieceModel(
        workspaceName: "Harness Monitor",
        destinationName: "My Mac",
        destinationSystemImage: "laptopcomputer",
        metrics: [
          .init(kind: .projects, value: contentUI.toolbarMetrics.projectCount),
          .init(kind: .worktrees, value: contentUI.toolbarMetrics.worktreeCount),
          .init(kind: .sessions, value: contentUI.toolbarMetrics.sessionCount),
          .init(kind: .openWork, value: contentUI.toolbarMetrics.openWorkCount),
          .init(kind: .blocked, value: contentUI.toolbarMetrics.blockedCount),
        ]
      ),
      displayMode: displayMode,
      statusMessages: contentUI.statusMessages.map(ToolbarStatusMessage.init),
      daemonIndicator: ToolbarDaemonIndicator(contentUI.daemonIndicator)
    )
  }
}

private struct ContentPrimaryToolbarItems: ToolbarContent {
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
  @Binding var showLlama: Bool
  @Binding var showInspector: Bool
  let openPreferences: () -> Void
  let refresh: () -> Void
  let toggleSleepPrevention: () -> Void

  init(
    contentUI: HarnessMonitorStore.ContentUISlice,
    showLlama: Binding<Bool>,
    showInspector: Binding<Bool>,
    openPreferences: @escaping () -> Void,
    refresh: @escaping () -> Void,
    toggleSleepPrevention: @escaping () -> Void
  ) {
    self.contentUI = contentUI
    self._showLlama = showLlama
    self._showInspector = showInspector
    self.openPreferences = openPreferences
    self.refresh = refresh
    self.toggleSleepPrevention = toggleSleepPrevention
  }

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      RefreshToolbarButton(isRefreshing: contentUI.isRefreshing, refresh: refresh)
        .help("Refresh sessions")

      Button(action: openPreferences) {
        Label("Settings", systemImage: "gearshape")
      }
      .help("Open settings")
      .accessibilityIdentifier(HarnessMonitorAccessibility.daemonPreferencesButton)
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItemGroup(placement: .primaryAction) {
      Button(action: toggleSleepPrevention) {
        Label(
          contentUI.sleepPreventionEnabled ? "Sleep Prevention On" : "Prevent Sleep",
          systemImage: contentUI.sleepPreventionEnabled ? "moon.zzz.fill" : "moon.zzz"
        )
      }
      .tint(contentUI.sleepPreventionEnabled ? .orange : nil)
      .help(
        contentUI.sleepPreventionEnabled
          ? "Preventing sleep - click to disable"
          : "Allow sleep - click to prevent"
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.sleepPreventionButton)
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItemGroup(placement: .primaryAction) {
      Button { showLlama.toggle() } label: {
        Label(
          showLlama ? "Hide Llama" : "Show Llama",
          systemImage: showLlama ? "hare.fill" : "hare"
        )
      }
      .tint(showLlama ? .purple : nil)
      .help(showLlama ? "Hide dancing llama" : "Show dancing llama")
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItemGroup(placement: .primaryAction) {
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

private struct ContentToolbarAccessibilityMarker: View {
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice

  init(contentUI: HarnessMonitorStore.ContentUISlice) {
    self.contentUI = contentUI
  }

  var body: some View {
    AccessibilityTextMarker(
      identifier: HarnessMonitorAccessibility.toolbarCenterpieceState,
      text: ToolbarCenterpieceModel(
        workspaceName: "Harness Monitor",
        destinationName: "My Mac",
        destinationSystemImage: "laptopcomputer",
        metrics: [
          .init(kind: .projects, value: contentUI.toolbarMetrics.projectCount),
          .init(kind: .worktrees, value: contentUI.toolbarMetrics.worktreeCount),
          .init(kind: .sessions, value: contentUI.toolbarMetrics.sessionCount),
          .init(kind: .openWork, value: contentUI.toolbarMetrics.openWorkCount),
          .init(kind: .blocked, value: contentUI.toolbarMetrics.blockedCount),
        ]
      ).accessibilityValue
    )
  }
}

// TODO: Restore when TableViewListCore_Mac2 preview crash is fixed (macOS 26 SwiftUI bug)
// #Preview("Dashboard") {
//   ContentView(store: HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded))
//     .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
// }
//
// #Preview("Cockpit shell") {
//   ContentView(store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded))
//     .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
// }
