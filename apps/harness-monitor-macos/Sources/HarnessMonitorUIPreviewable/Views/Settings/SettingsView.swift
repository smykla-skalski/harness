import HarnessMonitorKit
import SwiftUI

private let settingsDiagnosticsSnapshotWorker = SettingsDiagnosticsSnapshotWorker()

public struct SettingsView: View {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  @Binding var themeMode: HarnessMonitorThemeMode
  @Binding var selectedSection: SettingsSection
  @Binding var navigationRequest: SettingsNavigationRequest?
  @State private var selectedSupervisorPane: SupervisorPaneKey = .rules
  @State private var preparedDiagnosticsInput: SettingsDiagnosticsSnapshotInput?
  @State private var preparedDiagnosticsSnapshot: SettingsDiagnosticsSnapshot?

  public init(
    store: HarnessMonitorStore,
    notifications: HarnessMonitorUserNotificationController,
    themeMode: Binding<HarnessMonitorThemeMode>,
    selectedSection: Binding<SettingsSection>,
    navigationRequest: Binding<SettingsNavigationRequest?> = .constant(nil)
  ) {
    self.store = store
    self.notifications = notifications
    _themeMode = themeMode
    _selectedSection = selectedSection
    _navigationRequest = navigationRequest
  }

  public var body: some View {
    NavigationSplitView {
      SettingsSidebarList(selection: $selectedSection)
        .navigationSplitViewColumnWidth(
          min: SettingsChromeMetrics.sidebarMinWidth,
          ideal: SettingsChromeMetrics.sidebarIdealWidth,
          max: SettingsChromeMetrics.sidebarMaxWidth
        )
        .toolbarBaselineFrame(.sidebar)
    } detail: {
      Group {
        switch selectedSection {
        case .general:
          let overview = SettingsGeneralOverviewState(store: store)
          SettingsGeneralSection(store: store, overview: overview)
        case .focusMode:
          SettingsFocusModeSection()
        case .banners:
          SettingsBannersSection()
        case .appearance:
          SettingsAppearanceSection(themeMode: $themeMode)
        case .notifications:
          SettingsNotificationsSection(notifications: notifications)
        case .voice:
          SettingsVoiceSection()
        case .connection:
          let snapshot = SettingsConnectionSnapshot(store: store)
          SettingsConnectionSection(
            connectionState: snapshot.connectionState,
            isDiagnosticsRefreshInFlight: snapshot.isDiagnosticsRefreshInFlight,
            metrics: snapshot.metrics,
            events: snapshot.events,
            reconnect: { await store.reconnect() },
            refreshDiagnostics: { await store.refreshDiagnostics() }
          )
        case .taskBoard:
          SettingsTaskBoardSection(
            store: store,
            navigationRequest: $navigationRequest
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .policies:
          SettingsPoliciesSection()
        case .codex:
          SettingsHostBridgeSection(store: store)
        case .mcp:
          SettingsMCPSection(store: store)
        case .authorizedFolders:
          AuthorizedFoldersSection(store: store)
        case .supervisor:
          SettingsSupervisorSection(
            store: store,
            notifications: notifications,
            selectedPane: $selectedSupervisorPane
          )
        case .database:
          SettingsDatabaseSection(store: store)
        case .diagnostics:
          let input = SettingsDiagnosticsSnapshotInput(store: store)
          Group {
            if preparedDiagnosticsInput == input, let snapshot = preparedDiagnosticsSnapshot {
              SettingsDiagnosticsSection(
                snapshot: snapshot,
                revealPermissionLog: { runID, path in
                  guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  else {
                    return .unavailable
                  }
                  return store.revealAcpPermissionLogInFinder(runID: runID, rawPath: path)
                },
                repairLaunchAgent: { await store.repairLaunchAgent() }
              )
            } else {
              ProgressView("Loading diagnostics...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
          .task(id: input) {
            await syncDiagnosticsSnapshot(input: input)
          }
        }
      }
      .environment(\.settingsScrollRestorationSection, selectedSection)
      .environment(
        \.settingsScrollRestorationSuspended,
        navigationRequest?.target.section == selectedSection
      )
      .harnessMonitorBackgroundExtensionEffect()
    }
    .navigationSplitViewStyle(.balanced)
    .toolbarBaselineOverlay()
    .suppressToolbarBaselineSeparator(
      markedAs: HarnessMonitorAccessibility.settingsToolbarSeparatorSuppressed,
      titlebarAppearsTransparent: true
    )
    .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
    .toolbar {
      settingsToolbarItems
    }
    .containerBackground(.windowBackground, for: .window)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRoot)
    .onChange(of: navigationRequest, initial: true) { _, request in
      guard let request else { return }
      selectedSection = request.target.section
    }
    .overlay {
      SettingsOverlayMarkers(
        themeMode: themeMode,
        selectedSection: selectedSection
      )
    }
    .accessibilityFrameMarker(HarnessMonitorAccessibility.settingsPanel)
  }

  @MainActor
  private func syncDiagnosticsSnapshot(input: SettingsDiagnosticsSnapshotInput) async {
    guard preparedDiagnosticsInput != input else { return }
    let snapshot = await settingsDiagnosticsSnapshotWorker.prepare(input: input)
    guard !Task.isCancelled else { return }
    preparedDiagnosticsInput = input
    preparedDiagnosticsSnapshot = snapshot
  }

  @ToolbarContentBuilder private var settingsToolbarItems: some ToolbarContent {
    if selectedSection == .supervisor {
      ToolbarItem(placement: .primaryAction) {
        SupervisorSettingsToolbarPicker(selection: $selectedSupervisorPane)
      }
      .sharedBackgroundVisibility(.hidden)
    }
  }
}

private struct SettingsConnectionSnapshot {
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
