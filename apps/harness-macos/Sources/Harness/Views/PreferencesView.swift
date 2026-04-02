import HarnessKit
import SwiftUI

struct PreferencesView: View {
  let store: HarnessStore
  @Binding var themeMode: HarnessThemeMode
  @State private var selectedSection: PreferencesSection = .general

  var body: some View {
    NavigationSplitView {
      PreferencesSidebarList(selection: $selectedSection)
        .navigationSplitViewColumnWidth(
          min: PreferencesChromeMetrics.sidebarMinWidth,
          ideal: PreferencesChromeMetrics.sidebarIdealWidth,
          max: PreferencesChromeMetrics.sidebarMaxWidth
        )
    } detail: {
      switch selectedSection {
      case .general:
        PreferencesGeneralSection(store: store, themeMode: $themeMode)
      case .connection:
        PreferencesConnectionSection(store: store)
      case .diagnostics:
        PreferencesDiagnosticsSection(store: store)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .containerBackground(.windowBackground, for: .window)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.preferencesRoot)
    .overlay {
      PreferencesOverlayMarkers(themeMode: themeMode)
    }
    .accessibilityFrameMarker(HarnessAccessibility.preferencesPanel)
  }
}
