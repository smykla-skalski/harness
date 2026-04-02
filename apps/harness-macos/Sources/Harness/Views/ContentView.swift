import HarnessKit
import SwiftUI

struct ContentView: View {
  @Bindable var store: HarnessStore
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
      workspaceName: "AI Harness",
      destinationName: "My Mac",
      destinationSystemImage: "laptopcomputer",
      metrics: [
        .init(kind: .projects, value: store.daemonStatus?.projectCount ?? store.projects.count),
        .init(kind: .sessions, value: store.daemonStatus?.sessionCount ?? store.sessions.count),
        .init(kind: .openWork, value: store.totalOpenWorkCount),
        .init(kind: .blocked, value: store.totalBlockedCount),
      ]
    )
  }

  var body: some View {
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
      }
      .backgroundExtensionEffect()
      .accessibilityFrameMarker("\(HarnessAccessibility.contentRoot).frame")
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
    .inspector(isPresented: $showInspector) {
      InspectorColumnView(store: store)
        .inspectorColumnWidth(min: 320, ideal: 380, max: 500)
        .toolbar(id: "harness.inspector") {
          inspectorToolbar
        }
    }
    .navigationSplitViewStyle(.prominentDetail)
    .toolbarBaselineOverlay()
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.appChromeRoot)
    .overlay {
      ZStack {
        AccessibilityTextMarker(
          identifier: HarnessAccessibility.appChromeState,
          text: appChromeAccessibilityValue
        )
        AccessibilityTextMarker(
          identifier: HarnessAccessibility.toolbarChromeState,
          text: toolbarChromeAccessibilityValue
        )
        AccessibilityTextMarker(
          identifier: HarnessAccessibility.toolbarCenterpieceState,
          text: toolbarCenterpieceModel.accessibilityValue
        )
        AccessibilityTextMarker(
          identifier: HarnessAccessibility.toolbarCenterpieceMode,
          text: toolbarCenterpieceDisplayMode.rawValue
        )
      }
    }
    .modifier(HarnessConfirmationDialogModifier(store: store))
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

  @ToolbarContentBuilder var centerpieceToolbar: some ToolbarContent {
    ContentCenterpieceToolbar(
      model: toolbarCenterpieceModel,
      displayMode: toolbarCenterpieceDisplayMode
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
          openWindow(id: HarnessWindowID.preferences)
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .help("Open settings")
        .accessibilityIdentifier(HarnessAccessibility.daemonPreferencesButton)
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
          openWindow(id: HarnessWindowID.preferences)
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .help("Open settings")
        .accessibilityIdentifier(HarnessAccessibility.daemonPreferencesButton)
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

#Preview("Dashboard") {
  ContentView(store: HarnessPreviewStoreFactory.makeStore(for: .dashboardLoaded))
}

#Preview("Cockpit shell") {
  ContentView(store: HarnessPreviewStoreFactory.makeStore(for: .cockpitLoaded))
}
