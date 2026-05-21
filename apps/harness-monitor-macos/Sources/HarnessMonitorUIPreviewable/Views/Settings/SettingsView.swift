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
      SettingsDetailSwitch(
        store: store,
        notifications: notifications,
        themeMode: $themeMode,
        selectedSection: selectedSection,
        navigationRequest: $navigationRequest,
        selectedSupervisorPane: $selectedSupervisorPane
      )
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
      if case .section = request.target {
        navigationRequest = nil
      }
    }
    .overlay {
      SettingsOverlayMarkers(
        themeMode: themeMode,
        selectedSection: selectedSection
      )
    }
    .accessibilityFrameMarker(HarnessMonitorAccessibility.settingsPanel)
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

/// Holds per-section editable state (task-board form, diagnostics snapshot
/// cache) outside of `SettingsView`. Per-keystroke writes in the task-board,
/// repositories, and secrets sections previously invalidated the entire
/// `SettingsView` body - including the toolbar, navigation chrome, and
/// titlebar separator overrides. Moving the storage one level down means
/// only this switch's body re-evaluates on each keystroke; the outer
/// `NavigationSplitView` modifier chain stays stable.
private struct SettingsDetailSwitch: View {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  @Binding var themeMode: HarnessMonitorThemeMode
  let selectedSection: SettingsSection
  @Binding var navigationRequest: SettingsNavigationRequest?
  @Binding var selectedSupervisorPane: SupervisorPaneKey
  @State private var taskBoardFormState = TaskBoardSettingsFormState()
  @State private var preparedDiagnosticsInput: SettingsDiagnosticsSnapshotInput?
  @State private var preparedDiagnosticsSnapshot: SettingsDiagnosticsSnapshot?

  var body: some View {
    Group {
      switch selectedSection {
      case .general:
        SettingsGeneralSectionRoot(store: store)
      case .focusMode:
        SettingsFocusModeSection()
      case .banners:
        SettingsBannersSection()
      case .appearance:
        SettingsAppearanceSection(themeMode: $themeMode)
      case .markdown:
        SettingsMarkdownSection()
      case .notifications:
        SettingsNotificationsSection(notifications: notifications)
      case .voice:
        SettingsVoiceSection()
      case .connection:
        SettingsConnectionSectionRoot(store: store)
      case .taskBoard:
        SettingsTaskBoardSection(
          store: store,
          formState: $taskBoardFormState,
          navigationRequest: $navigationRequest
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      case .repositories:
        SettingsRepositoriesSection(
          store: store,
          formState: $taskBoardFormState
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      case .dependencies:
        SettingsDependenciesSection(navigationRequest: $navigationRequest)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      case .secrets:
        SettingsSecretsSection(
          store: store,
          formState: $taskBoardFormState
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
        SettingsDiagnosticsSectionRoot(
          store: store,
          preparedInput: $preparedDiagnosticsInput,
          preparedSnapshot: $preparedDiagnosticsSnapshot
        )
      }
    }
    .harnessGlassContainerScope()
    .environment(\.settingsScrollRestorationSection, selectedSection)
    .environment(
      \.settingsScrollRestorationSuspended,
      navigationRequest?.target.section == selectedSection
    )
    .harnessMonitorBackgroundExtensionEffect()
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

/// Thin wrapper that confines `SettingsGeneralOverviewState`'s store reads to
/// its own body, so unrelated store updates do not invalidate `SettingsView`.
private struct SettingsGeneralSectionRoot: View {
  let store: HarnessMonitorStore

  var body: some View {
    let overview = SettingsGeneralOverviewState(store: store)
    SettingsGeneralSection(store: store, overview: overview)
  }
}

/// Thin wrapper that confines connection-snapshot store reads (including the
/// `connectionEvents` array copy) to its own body, so connection telemetry
/// updates only invalidate the connection section, not the whole `SettingsView`.
private struct SettingsConnectionSectionRoot: View {
  let store: HarnessMonitorStore

  var body: some View {
    let snapshot = SettingsConnectionSnapshot(store: store)
    SettingsConnectionSection(
      connectionState: snapshot.connectionState,
      isDiagnosticsRefreshInFlight: snapshot.isDiagnosticsRefreshInFlight,
      metrics: snapshot.metrics,
      events: snapshot.events,
      reconnect: { await store.reconnect() },
      refreshDiagnostics: { await store.refreshDiagnostics() }
    )
  }
}

/// Thin wrapper that confines `SettingsDiagnosticsSnapshotInput`'s store reads
/// (including four array copies) to its own body. The `@State` for the cached
/// snapshot stays on `SettingsView` via `@Binding`, so revisiting the diagnostics
/// section after switching does not flash the loading state.
private struct SettingsDiagnosticsSectionRoot: View {
  let store: HarnessMonitorStore
  @Binding var preparedInput: SettingsDiagnosticsSnapshotInput?
  @Binding var preparedSnapshot: SettingsDiagnosticsSnapshot?

  var body: some View {
    let input = SettingsDiagnosticsSnapshotInput(store: store)
    Group {
      if preparedInput == input, let snapshot = preparedSnapshot {
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
      guard preparedInput != input else { return }
      let snapshot = await settingsDiagnosticsSnapshotWorker.prepare(input: input)
      guard !Task.isCancelled else { return }
      preparedInput = input
      preparedSnapshot = snapshot
    }
  }
}
