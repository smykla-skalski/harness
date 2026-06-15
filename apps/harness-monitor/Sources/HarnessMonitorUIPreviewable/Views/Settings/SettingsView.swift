import HarnessMonitorKit
import SwiftUI

public struct SettingsView: View {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let mobilePairingContent: (@MainActor @Sendable () -> AnyView)?
  @Binding var themeMode: HarnessMonitorThemeMode
  @Binding var selectedSection: SettingsSection
  @Binding var navigationRequest: SettingsNavigationRequest?
  @State private var selectedSupervisorPane: SupervisorPaneKey = .rules
  @State private var selectedReviewsPane: ReviewsPaneKey = .general

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
        selectedSupervisorPane: $selectedSupervisorPane,
        selectedReviewsPane: $selectedReviewsPane
      )
      .toolbar {
        settingsToolbarItems
      }
    }
    .navigationSplitViewStyle(.balanced)
    .toolbarBaselineOverlay()
    .suppressToolbarBaselineSeparator(
      markedAs: HarnessMonitorAccessibility.settingsToolbarSeparatorSuppressed,
      titlebarAppearsTransparent: true
    )
    .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
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
    GlobalPolicyEnforcementToolbarGroup(store: store)

    if selectedSection == .supervisor {
      ToolbarSpacer(.fixed, placement: .primaryAction)
        .sharedBackgroundVisibility(.hidden)
      ToolbarItem(placement: .primaryAction) {
        SupervisorSettingsToolbarPicker(selection: $selectedSupervisorPane)
      }
      .sharedBackgroundVisibility(.hidden)
    } else if selectedSection == .reviews {
      ToolbarSpacer(.fixed, placement: .primaryAction)
        .sharedBackgroundVisibility(.hidden)
      ToolbarItem(placement: .primaryAction) {
        ReviewsSettingsToolbarPicker(selection: $selectedReviewsPane)
      }
      .sharedBackgroundVisibility(.hidden)
    }
  }
}
