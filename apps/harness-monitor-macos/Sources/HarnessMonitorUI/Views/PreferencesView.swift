import HarnessMonitorKit
import SwiftUI

public struct PreferencesView: View {
  let store: HarnessMonitorStore
  @Binding var themeMode: HarnessMonitorThemeMode
  @Binding var selectedSection: PreferencesSection

  public init(
    store: HarnessMonitorStore,
    themeMode: Binding<HarnessMonitorThemeMode>,
    selectedSection: Binding<PreferencesSection>
  ) {
    self.store = store
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
          PreferencesGeneralSection(store: store)
        case .appearance:
          PreferencesAppearanceSection(themeMode: $themeMode)
        case .connection:
          PreferencesConnectionSection(
            connectionState: store.connectionState,
            isDiagnosticsRefreshInFlight: store.isDiagnosticsRefreshInFlight,
            metrics: store.connectionMetrics,
            events: store.connectionEvents,
            reconnect: { await store.reconnect() },
            refreshDiagnostics: { await store.refreshDiagnostics() }
          )
        case .database:
          PreferencesDatabaseSection(store: store)
        case .diagnostics:
          PreferencesDiagnosticsSection(store: store)
        }
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
