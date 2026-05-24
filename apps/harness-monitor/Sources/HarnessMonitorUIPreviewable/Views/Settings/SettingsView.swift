import HarnessMonitorKit
import SwiftUI

private let settingsDiagnosticsSnapshotWorker = SettingsDiagnosticsSnapshotWorker()

public struct SettingsView: View {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let mobilePairingContent: (@MainActor @Sendable () -> AnyView)?
  @Binding var themeMode: HarnessMonitorThemeMode
  @Binding var selectedSection: SettingsSection
  @Binding var navigationRequest: SettingsNavigationRequest?
  @State private var selectedSupervisorPane: SupervisorPaneKey = .rules

  public init(
    store: HarnessMonitorStore,
    notifications: HarnessMonitorUserNotificationController,
    mobilePairingContent: (@MainActor @Sendable () -> AnyView)? = nil,
    themeMode: Binding<HarnessMonitorThemeMode>,
    selectedSection: Binding<SettingsSection>,
    navigationRequest: Binding<SettingsNavigationRequest?> = .constant(nil)
  ) {
    self.store = store
    self.notifications = notifications
    self.mobilePairingContent = mobilePairingContent
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
        mobilePairingContent: mobilePairingContent,
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
      if let pane = request.supervisorPane {
        selectedSupervisorPane = pane
      }
      switch request.target {
      case .section, .supervisor:
        navigationRequest = nil
      case .taskBoard:
        break
      }
    }
    .overlay {
      if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
        SettingsOverlayMarkers(
          themeMode: themeMode,
          selectedSection: selectedSection
        )
      }
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
/// cache) outside of `SettingsView`, and lazy-mounts each section into a
/// retained layout so subsequent visits don't pay SwiftUI's view-tree rebuild
/// cost.
///
/// Retention semantics:
/// - First visit to a section: full build cost.
/// - Any subsequent visit: instant. The view tree stays mounted, but inactive
///   sections are not measured or placed. ScrollView state preserved.
/// - Each retained section gets its own `\.settingsScrollRestorationSection`
///   env override so SettingsScrollRestorationModifier targets the right
///   per-section persisted offset.
///
/// Trade-off: sections with `.task { await refresh() }` only refresh on first
/// visit per Settings session.
private struct SettingsDetailSwitch: View {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let mobilePairingContent: (@MainActor @Sendable () -> AnyView)?
  @Binding var themeMode: HarnessMonitorThemeMode
  let selectedSection: SettingsSection
  @Binding var navigationRequest: SettingsNavigationRequest?
  @Binding var selectedSupervisorPane: SupervisorPaneKey
  @State private var taskBoardFormState = TaskBoardSettingsFormState()
  @State private var preparedDiagnosticsInput: SettingsDiagnosticsSnapshotInput?
  @State private var preparedDiagnosticsSnapshot: SettingsDiagnosticsSnapshot?
  @State private var visitedSections: Set<SettingsSection> = []

  var body: some View {
    SettingsRetainedSectionLayout(selectedSection: selectedSection) {
      ForEach(SettingsSection.allCases, id: \.self) { section in
        if visitedSections.contains(section) {
          let isSelected = section == selectedSection
          SettingsRetainedSectionHost(
            section: section,
            isSelected: isSelected,
            isRestorationSuspended: isSelected && navigationRequest?.target.section == section
          ) {
            sectionContent(section)
          }
          .equatable()
          .layoutValue(key: SettingsRetainedSectionKey.self, value: section)
        }
      }
    }
    .harnessGlassContainerScope()
    .harnessMonitorBackgroundExtensionEffect()
    .onChange(of: selectedSection, initial: true) { _, newValue in
      visit(newValue)
    }
  }

  private func visit(_ section: SettingsSection) {
    guard !visitedSections.contains(section) else {
      return
    }
    visitedSections.insert(section)
  }

  @ViewBuilder
  private func sectionContent(_ section: SettingsSection) -> some View {
    switch section {
    case .general, .focusMode, .banners, .appearance, .markdown, .notifications, .voice,
      .connection, .mobile:
      primarySectionContent(section)
    case .taskBoard, .repositories, .reviews, .secrets:
      taskBoardSectionContent(section)
    case .policies, .codex, .mcp, .authorizedFolders:
      integrationSectionContent(section)
    case .supervisor, .database, .diagnostics:
      operationsSectionContent(section)
    }
  }

  @ViewBuilder
  private func primarySectionContent(_ section: SettingsSection) -> some View {
    switch section {
    case .general:
      SettingsGeneralSectionRoot(store: store, isActive: section == selectedSection)
    case .focusMode:
      SettingsFocusModeSection()
    case .banners:
      SettingsBannersSection()
    case .appearance:
      SettingsAppearanceSection(themeMode: $themeMode)
    case .markdown:
      SettingsMarkdownSection()
    case .notifications:
      SettingsNotificationsSection(
        notifications: notifications,
        isActive: section == selectedSection
      )
    case .voice:
      SettingsVoiceSection()
    case .connection:
      SettingsConnectionSectionRoot(
        store: store,
        isActive: section == selectedSection
      )
    case .mobile:
      SettingsMobileSection(pairingContent: mobilePairingContent)
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private func taskBoardSectionContent(_ section: SettingsSection) -> some View {
    switch section {
    case .taskBoard:
      SettingsTaskBoardSection(
        store: store,
        formState: $taskBoardFormState,
        isActive: section == selectedSection,
        navigationRequest: $navigationRequest
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    case .repositories:
      SettingsRepositoriesSection(
        store: store,
        formState: $taskBoardFormState,
        isActive: section == selectedSection
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    case .reviews:
      SettingsReviewsSection(
        isActive: section == selectedSection,
        navigationRequest: $navigationRequest
      )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    case .secrets:
      SettingsSecretsSection(
        store: store,
        formState: $taskBoardFormState,
        isActive: section == selectedSection
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private func integrationSectionContent(_ section: SettingsSection) -> some View {
    switch section {
    case .policies:
      SettingsPoliciesSection()
    case .codex:
      SettingsHostBridgeSection(store: store, isActive: section == selectedSection)
    case .mcp:
      SettingsMCPSection(store: store, isActive: section == selectedSection)
    case .authorizedFolders:
      AuthorizedFoldersSection(store: store, isActive: section == selectedSection)
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private func operationsSectionContent(_ section: SettingsSection) -> some View {
    switch section {
    case .supervisor:
      SettingsSupervisorSection(
        store: store,
        notifications: notifications,
        isActive: section == selectedSection,
        selectedPane: $selectedSupervisorPane
      )
    case .database:
      SettingsDatabaseSection(store: store, isActive: section == selectedSection)
    case .diagnostics:
      SettingsDiagnosticsSectionRoot(
        store: store,
        isActive: section == selectedSection,
        preparedInput: $preparedDiagnosticsInput,
        preparedSnapshot: $preparedDiagnosticsSnapshot
      )
    default:
      EmptyView()
    }
  }
}

private struct SettingsRetainedSectionHost<Content: View>: View, Equatable {
  let section: SettingsSection
  let isSelected: Bool
  let isRestorationSuspended: Bool
  private let content: () -> Content

  init(
    section: SettingsSection,
    isSelected: Bool,
    isRestorationSuspended: Bool,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.section = section
    self.isSelected = isSelected
    self.isRestorationSuspended = isRestorationSuspended
    self.content = content
  }

  var body: some View {
    content()
      .environment(\.settingsScrollRestorationSection, isSelected ? section : nil)
      .environment(\.settingsScrollRestorationSuspended, isRestorationSuspended)
      .harnessMCPElementTrackingEnabled(isSelected)
      .opacity(isSelected ? 1 : 0)
      .allowsHitTesting(isSelected)
      .accessibilityHidden(!isSelected)
  }

  nonisolated static func == (
    lhs: SettingsRetainedSectionHost<Content>,
    rhs: SettingsRetainedSectionHost<Content>
  ) -> Bool {
    lhs.section == rhs.section
      && lhs.isSelected == rhs.isSelected
      && lhs.isRestorationSuspended == rhs.isRestorationSuspended
  }
}

private struct SettingsRetainedSectionLayout: Layout {
  let selectedSection: SettingsSection

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    selectedSubview(in: subviews)?.sizeThatFits(proposal) ?? .zero
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    selectedSubview(in: subviews)?.place(
      at: bounds.origin,
      proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
    )
  }

  func explicitAlignment(
    of _: HorizontalAlignment,
    in _: CGRect,
    proposal _: ProposedViewSize,
    subviews _: Subviews,
    cache _: inout ()
  ) -> CGFloat? {
    nil
  }

  func explicitAlignment(
    of _: VerticalAlignment,
    in _: CGRect,
    proposal _: ProposedViewSize,
    subviews _: Subviews,
    cache _: inout ()
  ) -> CGFloat? {
    nil
  }

  private func selectedSubview(in subviews: Subviews) -> LayoutSubview? {
    subviews.first { subview in
      subview[SettingsRetainedSectionKey.self] == selectedSection
    } ?? subviews.first
  }
}

private struct SettingsRetainedSectionKey: LayoutValueKey {
  static let defaultValue: SettingsSection? = nil
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

private struct SettingsGeneralSnapshot: Equatable, Sendable {
  let overview: SettingsGeneralOverviewState
  let liveState: SettingsGeneralLiveState

  @MainActor
  init(store: HarnessMonitorStore) {
    overview = SettingsGeneralOverviewState(store: store)
    liveState = SettingsGeneralLiveState(store: store)
  }
}

/// Thin wrapper that confines `SettingsGeneralOverviewState`'s store reads to
/// its own body, so unrelated store updates do not invalidate `SettingsView`.
private struct SettingsGeneralSectionRoot: View {
  let store: HarnessMonitorStore
  let isActive: Bool
  @State private var cachedSnapshot: SettingsGeneralSnapshot?

  var body: some View {
    let activeSnapshot = isActive ? SettingsGeneralSnapshot(store: store) : nil
    Group {
      if let snapshot = activeSnapshot ?? cachedSnapshot {
        SettingsGeneralSection(
          store: store,
          overview: snapshot.overview,
          liveState: snapshot.liveState
        )
      } else {
        ProgressView("Loading general settings...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: activeSnapshot) {
      guard let activeSnapshot else { return }
      cachedSnapshot = activeSnapshot
    }
  }
}

/// Thin wrapper that confines connection-snapshot store reads (including the
/// `connectionEvents` array copy) to its own body, so connection telemetry
/// updates only invalidate the connection section, not the whole `SettingsView`.
private struct SettingsConnectionSectionRoot: View {
  let store: HarnessMonitorStore
  let isActive: Bool
  @State private var cachedSnapshot: SettingsConnectionSnapshot?

  var body: some View {
    let activeSnapshot = isActive ? SettingsConnectionSnapshot(store: store) : nil
    Group {
      if let snapshot = activeSnapshot ?? cachedSnapshot {
        SettingsConnectionSection(
          connectionState: snapshot.connectionState,
          isDiagnosticsRefreshInFlight: snapshot.isDiagnosticsRefreshInFlight,
          metrics: snapshot.metrics,
          events: snapshot.events,
          reconnect: { await store.reconnect() },
          refreshDiagnostics: { await store.refreshDiagnostics() }
        )
      } else {
        ProgressView("Loading connection...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: isActive) {
      guard isActive else { return }
      cachedSnapshot = SettingsConnectionSnapshot(store: store)
    }
  }
}

/// Thin wrapper that confines `SettingsDiagnosticsSnapshotInput`'s store reads
/// (including four array copies) to its own body. The `@State` for the cached
/// snapshot stays on `SettingsView` via `@Binding`, so revisiting the diagnostics
/// section after switching does not flash the loading state.
private struct SettingsDiagnosticsSectionRoot: View {
  let store: HarnessMonitorStore
  let isActive: Bool
  @Binding var preparedInput: SettingsDiagnosticsSnapshotInput?
  @Binding var preparedSnapshot: SettingsDiagnosticsSnapshot?

  var body: some View {
    let activeInput = isActive ? SettingsDiagnosticsSnapshotInput(store: store) : nil
    let displayedInput = activeInput ?? preparedInput
    Group {
      if let displayedInput,
        preparedInput == displayedInput,
        let snapshot = preparedSnapshot
      {
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
    .task(id: activeInput) {
      guard let input = activeInput else { return }
      guard preparedInput != input else { return }
      let snapshot = await settingsDiagnosticsSnapshotWorker.prepare(input: input)
      guard !Task.isCancelled else { return }
      preparedInput = input
      preparedSnapshot = snapshot
    }
  }
}
