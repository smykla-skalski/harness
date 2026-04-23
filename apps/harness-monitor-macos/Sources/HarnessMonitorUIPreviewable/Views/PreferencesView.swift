import HarnessMonitorKit
import SwiftUI

public struct PreferencesView: View {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  @Binding var themeMode: HarnessMonitorThemeMode
  @Binding var selectedSection: PreferencesSection
  @State private var selectedSupervisorPane: SupervisorPaneKey = .rules

  public init(
    store: HarnessMonitorStore,
    notifications: HarnessMonitorUserNotificationController,
    themeMode: Binding<HarnessMonitorThemeMode>,
    selectedSection: Binding<PreferencesSection>
  ) {
    self.store = store
    self.notifications = notifications
    _themeMode = themeMode
    _selectedSection = selectedSection
  }

  public var body: some View {
    NavigationSplitView {
      PreferencesSidebarList(selection: $selectedSection)
        .navigationSplitViewColumnWidth(
          min: PreferencesChromeMetrics.sidebarMinWidth,
          ideal: PreferencesChromeMetrics.sidebarIdealWidth,
          max: PreferencesChromeMetrics.sidebarMaxWidth
        )
        .toolbarBaselineFrame(.sidebar)
    } detail: {
      Group {
        switch selectedSection {
        case .general:
          let overview = PreferencesGeneralOverviewState(store: store)
          PreferencesGeneralSection(store: store, overview: overview)
        case .appearance:
          PreferencesAppearanceSection(themeMode: $themeMode)
        case .notifications:
          PreferencesNotificationsSection(notifications: notifications)
        case .voice:
          PreferencesVoiceSection()
        case .connection:
          let snapshot = PreferencesConnectionSnapshot(store: store)
          PreferencesConnectionSection(
            connectionState: snapshot.connectionState,
            isDiagnosticsRefreshInFlight: snapshot.isDiagnosticsRefreshInFlight,
            metrics: snapshot.metrics,
            events: snapshot.events,
            reconnect: { await store.reconnect() },
            refreshDiagnostics: { await store.refreshDiagnostics() }
          )
        case .codex:
          PreferencesHostBridgeSection(store: store)
        case .mcp:
          PreferencesMCPSection()
        case .authorizedFolders:
          AuthorizedFoldersSection(store: store)
        case .supervisor:
          PreferencesSupervisorSection(
            store: store,
            notifications: notifications,
            selectedPane: $selectedSupervisorPane
          )
        case .database:
          PreferencesDatabaseSection(store: store)
        case .diagnostics:
          let snapshot = PreferencesDiagnosticsSnapshot(store: store)
          PreferencesDiagnosticsSection(snapshot: snapshot)
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .toolbarBaselineOverlay()
    .suppressToolbarBaselineSeparator(
      markedAs: HarnessMonitorAccessibility.preferencesToolbarSeparatorSuppressed
    )
    .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
    .toolbar {
      preferencesToolbarItems
    }
    .containerBackground(.windowBackground, for: .window)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesRoot)
    .overlay {
      PreferencesOverlayMarkers(
        themeMode: themeMode,
        selectedSection: selectedSection
      )
    }
    .accessibilityFrameMarker(HarnessMonitorAccessibility.preferencesPanel)
  }

  @ToolbarContentBuilder private var preferencesToolbarItems: some ToolbarContent {
    if selectedSection == .supervisor {
      ToolbarItem(placement: .primaryAction) {
        SupervisorPreferencesToolbarPicker(selection: $selectedSupervisorPane)
      }
      .sharedBackgroundVisibility(.hidden)
    }
  }
}

private struct PreferencesConnectionSnapshot {
  let connectionState: HarnessMonitorStore.ConnectionState
  let isDiagnosticsRefreshInFlight: Bool
  let metrics: ConnectionMetrics
  let events: [ConnectionEvent]

  @MainActor
  init(store: HarnessMonitorStore) {
    connectionState = store.connectionState
    isDiagnosticsRefreshInFlight = store.isDiagnosticsRefreshInFlight
    metrics = store.connectionMetrics
    events = store.connectionEvents
  }
}
