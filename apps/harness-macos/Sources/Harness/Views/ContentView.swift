import HarnessKit
import SwiftUI

struct ContentView: View {
  @Bindable var store: HarnessStore
  @Environment(\.openSettings)
  private var openSettings
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
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

  private var navigationTitle: String {
    if let detail = selectedDetail {
      return detail.session.context
    }
    if let summary = selectedSessionSummary {
      return summary.context
    }
    return "Harness"
  }

  private var chromeAccessibilityValue: String {
    [
      "contentChrome=native",
      "interactiveRows=button",
      "controlGlass=native",
    ].joined(separator: ", ")
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      SidebarView(store: store)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
    } detail: {
      ContentDetailChrome(
        persistenceError: store.persistenceError,
        cachedDataMessage: store.isShowingCachedData ? store.cachedDataStatusMessage : nil
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
      .navigationTitle(navigationTitle)
      .toolbar {
        navigationToolbar
      }
      .toolbar(id: "harness.main") {
        primaryToolbar
      }
    }
    .inspector(isPresented: $showInspector) {
      InspectorColumnView(store: store)
        .inspectorColumnWidth(min: 320, ideal: 380, max: 500)
    }
    .navigationSplitViewStyle(.prominentDetail)
    .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
    .containerBackground(.windowBackground, for: .window)
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
      AccessibilityTextMarker(
        identifier: HarnessAccessibility.appChromeState,
        text: chromeAccessibilityValue
      )
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

  @ToolbarContentBuilder var primaryToolbar: some CustomizableToolbarContent {
    ToolbarItem(id: "refresh", placement: .primaryAction) {
      RefreshToolbarButton(isRefreshing: store.isRefreshing, refresh: refresh)
        .help("Refresh sessions")
    }

    ToolbarItem(id: "settings", placement: .primaryAction) {
      Button {
        openSettings()
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
      .help("Open settings")
      .accessibilityIdentifier(HarnessAccessibility.daemonPreferencesButton)
    }

    ToolbarSpacer(.fixed)

    ToolbarItem(id: "inspector", placement: .primaryAction) {
      Button(action: toggleInspector) {
        Label(
          showInspector ? "Hide Inspector" : "Show Inspector",
          systemImage: "sidebar.trailing"
        )
      }
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
}

#Preview("Dashboard") {
  ContentView(store: HarnessPreviewStoreFactory.makeStore(for: .dashboardLoaded))
}

#Preview("Cockpit shell") {
  ContentView(store: HarnessPreviewStoreFactory.makeStore(for: .cockpitLoaded))
}
