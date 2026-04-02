import SwiftUI

#Preview("Preferences Window - General") {
  @Previewable @State var themeMode: HarnessThemeMode = .auto

  PreferencesView(
    store: PreferencesPreviewSupport.makeStore(),
    themeMode: $themeMode,
    selectedSection: .general
  )
  .frame(width: 980, height: 680)
}

#Preview("Preferences Window - Connection") {
  @Previewable @State var themeMode: HarnessThemeMode = .auto

  PreferencesView(
    store: PreferencesPreviewSupport.makeStore(),
    themeMode: $themeMode,
    selectedSection: .connection
  )
  .frame(width: 980, height: 680)
}

#Preview("Preferences Window - Diagnostics") {
  @Previewable @State var themeMode: HarnessThemeMode = .auto

  PreferencesView(
    store: PreferencesPreviewSupport.makeStore(),
    themeMode: $themeMode,
    selectedSection: .diagnostics
  )
  .frame(width: 980, height: 680)
}
