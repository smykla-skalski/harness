import HarnessKit
import Observation
import SwiftUI

struct InspectorVisibilityKey: FocusedValueKey {
  typealias Value = Binding<Bool>
}

extension FocusedValues {
  var inspectorVisibility: Binding<Bool>? {
    get { self[InspectorVisibilityKey.self] }
    set { self[InspectorVisibilityKey.self] = newValue }
  }
}

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
        isShowingCachedData: store.isShowingCachedData
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
        lastAction: $store.lastAction
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

private struct HarnessConfirmationDialogModifier: ViewModifier {
  @Bindable var store: HarnessStore

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        title,
        isPresented: $store.showConfirmation,
        titleVisibility: .visible
      ) {
        switch store.pendingConfirmation {
        case .endSession:
          Button("End Session Now", role: .destructive) {
            Task { await store.confirmPendingAction() }
          }
        case .removeAgent:
          Button("Remove Agent Now", role: .destructive) {
            Task { await store.confirmPendingAction() }
          }
        case .removeLaunchAgent:
          Button("Remove Launch Agent Now", role: .destructive) {
            Task { await store.confirmPendingAction() }
          }
        case nil:
          EmptyView()
        }
        Button("Cancel", role: .cancel) {
          store.cancelConfirmation()
        }
      } message: {
        if !message.isEmpty {
          Text(message)
        }
      }
  }

  private var title: String {
    switch store.pendingConfirmation {
    case .endSession: "End Session?"
    case .removeAgent: "Remove Agent?"
    case .removeLaunchAgent: "Remove Launch Agent?"
    case nil: ""
    }
  }

  private var message: String {
    switch store.pendingConfirmation {
    case .endSession(let sessionID, let actorID):
      "This ends \(sessionID) using \(actorID). Active task work must already be closed."
    case .removeAgent(_, let agentID, let actorID):
      "This removes \(agentID) using \(actorID) and returns any active work to the queue."
    case .removeLaunchAgent:
      "This disables launchd residency for the harness daemon on this Mac."
    case nil:
      ""
    }
  }
}

private struct ContentDetailChrome<Content: View>: View {
  let persistenceError: String?
  let isShowingCachedData: Bool
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      if let persistenceError {
        PersistenceUnavailableBanner(message: persistenceError)
      }
      if isShowingCachedData {
        CachedDataBanner()
      }
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct CachedDataBanner: View {
  var body: some View {
    HStack(spacing: HarnessTheme.itemSpacing) {
      Image(systemName: "cloud.bolt")
        .scaledFont(.caption)
        .accessibilityHidden(true)
      Text("Showing cached data - daemon is offline")
        .scaledFont(.caption.weight(.medium))
      Spacer()
    }
    .harnessCellPadding()
    .background(HarnessTheme.caution.opacity(0.12))
    .foregroundStyle(HarnessTheme.caution)
  }
}

private struct PersistenceUnavailableBanner: View {
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: HarnessTheme.itemSpacing) {
      Image(systemName: "externaldrive.badge.exclamationmark")
        .scaledFont(.caption)
        .accessibilityHidden(true)
      Text(message)
        .scaledFont(.caption.weight(.medium))
      Spacer(minLength: 0)
    }
    .harnessCellPadding()
    .background(HarnessTheme.caution.opacity(0.18))
    .foregroundStyle(HarnessTheme.caution)
    .accessibilityIdentifier(HarnessAccessibility.persistenceBanner)
  }
}

private struct ContentAnnouncementsModifier: ViewModifier {
  let connectionState: HarnessStore.ConnectionState
  @Binding var lastAction: String

  func body(content: Content) -> some View {
    content
      .onChange(of: connectionState) { _, newState in
        guard let message = message(for: newState) else { return }
        AccessibilityNotification.Announcement(message).post()
      }
      .onChange(of: lastAction) { _, action in
        guard !action.isEmpty else { return }
        AccessibilityNotification.Announcement(action).post()
      }
      .task(id: lastAction) {
        guard !lastAction.isEmpty else { return }
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled else { return }
        lastAction = ""
      }
  }

  private func message(for state: HarnessStore.ConnectionState) -> String? {
    switch state {
    case .online:
      "Connected to daemon"
    case .connecting:
      "Connecting to daemon"
    case .offline(let reason):
      "Disconnected: \(reason)"
    case .idle:
      nil
    }
  }
}

private struct ContentNavigationToolbar: ToolbarContent {
  let canNavigateBack: Bool
  let canNavigateForward: Bool
  let navigateBack: () -> Void
  let navigateForward: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      Button(action: navigateBack) {
        Label("Back", systemImage: "chevron.backward")
      }
      .disabled(!canNavigateBack)
      .help("Go back")
      .accessibilityIdentifier(HarnessAccessibility.navigateBackButton)
    }

    ToolbarItem(placement: .navigation) {
      Button(action: navigateForward) {
        Label("Forward", systemImage: "chevron.forward")
      }
      .disabled(!canNavigateForward)
      .help("Go forward")
      .accessibilityIdentifier(HarnessAccessibility.navigateForwardButton)
    }
  }
}

struct RefreshToolbarButton: View {
  let isRefreshing: Bool
  let refresh: () -> Void
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var isSpinning = false

  var body: some View {
    Button(action: refresh) {
      Label {
        Text("Refresh")
      } icon: {
        Image(systemName: "arrow.clockwise")
          .rotationEffect(.degrees(reduceMotion ? 0 : (isSpinning ? 360 : 0)))
          .animation(
            reduceMotion
              ? nil
              : isSpinning
              ? .linear(duration: 0.9).repeatForever(autoreverses: false)
              : .easeOut(duration: 0.4),
            value: isSpinning
          )
      }
    }
    .accessibilityIdentifier(HarnessAccessibility.refreshButton)
    .onChange(of: isRefreshing) { _, refreshing in
      isSpinning = refreshing
    }
  }
}

#Preview("Dashboard") {
  ContentView(store: HarnessPreviewStoreFactory.makeStore(for: .dashboardLoaded))
}

#Preview("Cockpit shell") {
  ContentView(store: HarnessPreviewStoreFactory.makeStore(for: .cockpitLoaded))
}
