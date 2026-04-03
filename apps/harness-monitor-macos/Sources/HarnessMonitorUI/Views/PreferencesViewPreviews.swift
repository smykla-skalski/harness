import HarnessMonitorKit
import SwiftUI

#Preview("Preferences Window - General") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .auto

  preferencesWindowPreview(
    section: .general,
    themeMode: $themeMode
  )
}

#Preview("Preferences Window - Connection") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .auto

  preferencesWindowPreview(
    section: .connection,
    themeMode: $themeMode
  )
}

#Preview("Preferences Window - Diagnostics") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .auto

  preferencesWindowPreview(
    section: .diagnostics,
    themeMode: $themeMode
  )
}

#Preview("Preferences Window - Diagnostics Error") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .dark

  preferencesWindowPreview(
    section: .diagnostics,
    themeMode: $themeMode,
    store: PreferencesPreviewSupport.makeStore(
      lastError: "Failed to read launchd state from the preview daemon."
    )
  )
}

@MainActor
private func preferencesWindowPreview(
  section: PreferencesSection,
  themeMode: Binding<HarnessMonitorThemeMode>,
  store: HarnessMonitorStore = PreferencesPreviewSupport.makeStore()
) -> some View {
  PreferencesView(
    store: store,
    themeMode: themeMode,
    initialSection: section
  )
  .frame(width: 780, height: 560)
}
