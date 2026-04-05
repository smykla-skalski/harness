import HarnessMonitorKit
import SwiftUI

public struct ContentView: View {
  @Bindable var store: HarnessMonitorStore
  @Environment(\.openWindow)
  private var openWindow
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var toolbarCenterpieceDisplayMode: ToolbarCenterpieceDisplayMode = .standard
  @SceneStorage("showInspector")
  private var showInspector = true
  @SceneStorage("selectedSessionID")
  private var restoredSessionID: String?

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
    NavigationSplitView(columnVisibility: $columnVisibility) {
      SidebarView(store: store)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        .toolbarBaselineFrame(.sidebar)
    } detail: {
      ContentDetailChrome(
        persistenceError: store.persistenceError,
        sessionDataAvailability: store.sessionDataAvailability
      ) {
        SessionContentContainer(
          store: store,
          detail: selectedDetail,
          summary: selectedSessionSummary,
          timeline: store.timeline
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .backgroundExtensionEffect()
        .accessibilityFrameMarker("\(HarnessMonitorAccessibility.contentRoot).frame")
        .onKeyPress(.escape) {
          if store.inspectorSelection != .none {
            store.inspectorSelection = .none
            return .handled
          }
          return .ignored
        }
        .navigationTitle(windowTitle)
        .toolbar {
          navigationToolbar
          centerpieceToolbar
        }
        .toolbar(id: "harness.main") {
          primaryToolbar
        }
      }
    }
    .inspector(isPresented: $showInspector) {
      InspectorColumnView(store: store)
        .inspectorColumnWidth(min: 320, ideal: 380, max: 500)
        .toolbar(id: "harness.inspector") {
          inspectorToolbar
        }
    }
    .navigationSplitViewStyle(.prominentDetail)
    .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
    .containerBackground(.windowBackground, for: .window)
    .background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: ToolbarWidthKey.self,
          value: proxy.size.width
        )
      }
    }
    .onPreferenceChange(ToolbarWidthKey.self) { windowWidth in
      let nextMode = ToolbarCenterpieceDisplayMode.forWindowWidth(windowWidth)
      guard nextMode != toolbarCenterpieceDisplayMode else {
        return
      }
      toolbarCenterpieceDisplayMode = nextMode
    }
    .focusedSceneValue(\.inspectorVisibility, $showInspector)
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
    .toolbarBaselineOverlay()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    [
      .init(text: "Running Harness Monitor", systemImage: "gearshape.fill", tint: .blue),
      .init(text: "\(store.sessions.count) sessions active", systemImage: "antenna.radiowaves.left.and.right", tint: .green),
      .init(text: "Daemon connected", systemImage: "checkmark.circle.fill", tint: .green),
    ]
  }

  @ToolbarContentBuilder var centerpieceToolbar: some ToolbarContent {
    ContentCenterpieceToolbar(
      model: toolbarCenterpieceModel,
      displayMode: toolbarCenterpieceDisplayMode,
      statusMessages: statusTickerMessages
    )
  }

  @ToolbarContentBuilder var primaryToolbar: some CustomizableToolbarContent {
    if !showInspector {
      ToolbarItem(id: "refresh", placement: .primaryAction) {
        RefreshToolbarButton(isRefreshing: store.isRefreshing, refresh: refresh)
          .help("Refresh sessions")
      }

      ToolbarItem(id: "settings", placement: .primaryAction) {
        Button {
          openWindow(id: HarnessMonitorWindowID.preferences)
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .help("Open settings")
        .accessibilityIdentifier(HarnessMonitorAccessibility.daemonPreferencesButton)
      }

      ToolbarSpacer(.fixed)

      ToolbarItem(id: "inspector", placement: .primaryAction) {
        Button(action: toggleInspector) {
          Label("Show Inspector", systemImage: "sidebar.trailing")
        }
        .help("Show inspector")
      }
    }
  }

  @ToolbarContentBuilder var inspectorToolbar: some CustomizableToolbarContent {
    if showInspector {
      ToolbarSpacer(.flexible, placement: .primaryAction)

      ToolbarItem(id: "inspector.refresh", placement: .primaryAction) {
        RefreshToolbarButton(isRefreshing: store.isRefreshing, refresh: refresh)
          .help("Refresh sessions")
      }

      ToolbarItem(id: "inspector.settings", placement: .primaryAction) {
        Button {
          openWindow(id: HarnessMonitorWindowID.preferences)
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .help("Open settings")
        .accessibilityIdentifier(HarnessMonitorAccessibility.daemonPreferencesButton)
      }

      ToolbarSpacer(.fixed)

      ToolbarItem(id: "inspector.hide", placement: .primaryAction) {
        Button {
          showInspector = false
        } label: {
          Label("Hide Inspector", systemImage: "sidebar.trailing")
        }
        .help("Hide inspector")
      }
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
}

private struct ToolbarWidthKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
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
