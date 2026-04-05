import HarnessMonitorKit
import SwiftUI

public struct PreferencesView: View {
  let store: HarnessMonitorStore
  @Binding var themeMode: HarnessMonitorThemeMode
  @State private var selectedSection: PreferencesSection = .general

  public init(store: HarnessMonitorStore, themeMode: Binding<HarnessMonitorThemeMode>) {
    self.init(
      store: store,
      themeMode: themeMode,
      initialSection: .general
    )
  }

  init(
    store: HarnessMonitorStore,
    themeMode: Binding<HarnessMonitorThemeMode>,
    initialSection: PreferencesSection
  ) {
    self.store = store
    _themeMode = themeMode
    _selectedSection = State(initialValue: initialSection)
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
      switch selectedSection {
      case .general:
        PreferencesGeneralSection(store: store, themeMode: $themeMode)
      case .connection:
        PreferencesConnectionSection(store: store)
      case .database:
        PreferencesDatabaseSection(store: store)
      case .diagnostics:
        PreferencesDiagnosticsSection(store: store)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .toolbarBaselineOverlay()
    .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
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
}
