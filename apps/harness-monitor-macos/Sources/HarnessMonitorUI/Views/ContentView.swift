import HarnessMonitorKit
import SwiftUI

private enum HarnessMonitorInspectorLayout {
  static let minWidth: CGFloat = 320
  static let idealWidth: CGFloat = 420
  static let maxWidth: CGFloat = 760
}

public struct ContentView: View {
  @Bindable var store: HarnessMonitorStore
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
  @AppStorage(HarnessMonitorToolbarStyleDefaults.modeKey)
  private var toolbarStyleRawValue = HarnessMonitorToolbarStyle.glass.rawValue
  private let toolbarGlassReproConfiguration = ToolbarGlassReproConfiguration.current

  private var toolbarStyle: HarnessMonitorToolbarStyle {
    HarnessMonitorToolbarStyle(rawValue: toolbarStyleRawValue) ?? .glass
  }

  private var selectedDetail: SessionDetail? {
    guard let sessionID = store.selectedSessionID,
      let detail = store.selectedSession,
      detail.session.sessionId == sessionID
    else {
      return nil
    }
    return detail
  }

  private var selectedSessionSummary: SessionSummary? {
    store.selectedSessionSummary
  }

  private var windowTitle: String {
    if selectedDetail != nil || selectedSessionSummary != nil {
      return "Cockpit"
    }
    return "Dashboard"
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
      "toolbarStyle=\(toolbarStyle.rawValue)",
    ].joined(separator: ", ")
  }

  private var toolbarCenterpieceModel: ToolbarCenterpieceModel {
    ToolbarCenterpieceModel(
      workspaceName: "Harness Monitor",
      destinationName: "My Mac",
      destinationSystemImage: "laptopcomputer",
      metrics: [
        .init(kind: .projects, value: store.daemonStatus?.projectCount ?? store.projects.count),
        .init(kind: .worktrees, value: store.daemonStatus?.worktreeCount ?? store.projects.reduce(0) { $0 + $1.worktrees.count }),
        .init(kind: .sessions, value: store.daemonStatus?.sessionCount ?? store.sessions.count),
        .init(kind: .openWork, value: store.totalOpenWorkCount),
        .init(kind: .blocked, value: store.totalBlockedCount),
      ]
    )
  }

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  public var body: some View {
    let sessionContent = SessionContentContainer(
      store: store,
      detail: selectedDetail,
      summary: selectedSessionSummary,
      timeline: store.timeline
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.contentRoot).frame")
    .onKeyPress(.escape) {
      if store.inspectorSelection != .none {
        store.inspectorSelection = .none
        return .handled
      }
      return .ignored
    }

    NavigationSplitView(columnVisibility: $columnVisibility) {
      SidebarView(store: store)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        .toolbarBaselineFrame(.sidebar)
    } detail: {
      Group {
        if toolbarGlassReproConfiguration.disablesContentDetailChrome {
          sessionContent
        } else {
          ContentDetailChrome(
            persistenceError: store.persistenceError,
            sessionDataAvailability: store.sessionDataAvailability,
            sessionStatus: selectedDetail?.session.status ?? selectedSessionSummary?.status
          ) {
            sessionContent
          }
        }
      }
      .inspector(isPresented: $showInspector) {
        InspectorColumnView(store: store)
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
    }
    .navigationSplitViewStyle(.prominentDetail)
    .navigationTitle(windowTitle)
    .toolbar {
      navigationToolbar
      centerpieceToolbar
    }
    .toolbar {
      primaryToolbar
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
      if let restoredSessionID, store.selectedSessionID == nil {
        Task { await store.selectSession(restoredSessionID) }
      }
    }
    .onChange(of: store.selectedSessionID) { _, newID in
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
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.toolbarCenterpieceState,
          text: toolbarCenterpieceModel.accessibilityValue
        )
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
      isPresented: store.isSelectionLoading
        || store.isExtensionsLoading
        || store.isRefreshing
        || store.connectionState == .connecting,
      presentationDelay: .milliseconds(400)
    )
    .modifier(HarnessMonitorConfirmationDialogModifier(store: store))
    .modifier(
      ContentAnnouncementsModifier(
        connectionState: store.connectionState,
        lastAction: store.lastAction
      )
    )
  }
}

private extension ContentView {
  @ToolbarContentBuilder var navigationToolbar: some ToolbarContent {
    ContentNavigationToolbar(
      canNavigateBack: store.canNavigateBack,
      canNavigateForward: store.canNavigateForward,
      navigateBack: navigateBack,
      navigateForward: navigateForward
    )
  }

  private var statusTickerMessages: [ToolbarStatusMessage] {
    var messages: [ToolbarStatusMessage] = []

    if store.connectionState == .connecting {
      messages.append(.init(id: "loading.connecting", text: "Connecting to the control plane", systemImage: "network", tint: .orange))
    }
    if store.isRefreshing {
      messages.append(.init(id: "loading.refreshing", text: "Refreshing session index", systemImage: "arrow.trianglehead.2.clockwise", tint: .orange))
    }
    if store.isSelectionLoading {
      messages.append(.init(id: "loading.session", text: "Loading session detail", systemImage: "doc.text.magnifyingglass", tint: .orange))
    }
    if store.isExtensionsLoading {
      messages.append(.init(id: "loading.extensions", text: "Loading observers and signals", systemImage: "antenna.radiowaves.left.and.right", tint: .orange))
    }

    messages.append(contentsOf: [
      .init(id: "status.running", text: "Running Harness Monitor", systemImage: "gearshape.fill", tint: .blue),
      .init(id: "status.sessions", text: "\(store.sessions.count) sessions active", systemImage: "antenna.radiowaves.left.and.right", tint: .green),
      .init(id: "status.daemon", text: "Daemon connected", systemImage: "checkmark.circle.fill", tint: .green),
    ])

    return messages
  }

  private var daemonIndicator: ToolbarDaemonIndicator {
    guard store.connectionState == .online else {
      return .offline
    }
    if store.daemonStatus?.launchAgent.installed == true {
      return .launchdConnected
    }
    return .manualConnected
  }

  @ToolbarContentBuilder var centerpieceToolbar: some ToolbarContent {
    ContentCenterpieceToolbar(
      model: toolbarCenterpieceModel,
      displayMode: toolbarCenterpieceDisplayMode,
      statusMessages: statusTickerMessages,
      daemonIndicator: daemonIndicator
    )
  }

  @ToolbarContentBuilder var primaryToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      RefreshToolbarButton(isRefreshing: store.isRefreshing, refresh: refresh)
        .help("Refresh sessions")

      Button {
        openWindow(id: HarnessMonitorWindowID.preferences)
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
      .help("Open settings")
      .accessibilityIdentifier(HarnessMonitorAccessibility.daemonPreferencesButton)
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItemGroup(placement: .primaryAction) {
      Button(action: toggleSleepPrevention) {
        Label(
          store.sleepPreventionEnabled ? "Sleep Prevention On" : "Prevent Sleep",
          systemImage: store.sleepPreventionEnabled ? "moon.zzz.fill" : "moon.zzz"
        )
      }
      .tint(store.sleepPreventionEnabled ? .orange : nil)
      .help(
        store.sleepPreventionEnabled
          ? "Preventing sleep - click to disable"
          : "Allow sleep - click to prevent"
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.sleepPreventionButton)
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItemGroup(placement: .primaryAction) {
      Button(action: toggleInspector) {
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

  func navigateBack() {
    Task { await store.navigateBack() }
  }

  func navigateForward() {
    Task { await store.navigateForward() }
  }

  func refresh() {
    Task { await store.refresh() }
  }

  func toggleInspector() {
    showInspector.toggle()
  }

  func toggleSleepPrevention() {
    store.sleepPreventionEnabled.toggle()
  }
}

private struct DetailBackgroundExtension<Content: View>: View {
  let isGlass: Bool
  @ViewBuilder let content: Content

  var body: some View {
    if isGlass {
      content.backgroundExtensionEffect()
    } else {
      content
    }
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
