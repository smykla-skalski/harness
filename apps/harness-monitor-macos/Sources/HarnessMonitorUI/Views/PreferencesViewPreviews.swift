import SwiftUI

#Preview("Preferences Window - General") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .auto

  PreferencesView(
    store: PreferencesPreviewSupport.makeStore(),
    themeMode: $themeMode
  )
  .frame(width: 780, height: 560)
}

#Preview("Preferences Window - Connection") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .auto

  PreferencesView(
    store: PreferencesPreviewSupport.makeStore(),
    themeMode: $themeMode
  )
  .frame(width: 780, height: 560)
}

#Preview("Preferences Window - Diagnostics") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .auto

  PreferencesView(
    store: PreferencesPreviewSupport.makeStore(),
    themeMode: $themeMode
  )
  .frame(width: 780, height: 560)
}
