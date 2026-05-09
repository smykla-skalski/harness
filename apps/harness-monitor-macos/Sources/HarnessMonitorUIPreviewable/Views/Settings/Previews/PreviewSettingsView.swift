import HarnessMonitorKit
import SwiftUI

#Preview("Settings Window - General") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .auto

  settingsWindowPreview(
    section: .general,
    themeMode: $themeMode
  )
}

#Preview("Settings Window - Focus Mode") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .auto

  settingsWindowPreview(
    section: .focusMode,
    themeMode: $themeMode
  )
}

#Preview("Settings Window - Banners") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .auto

  settingsWindowPreview(
    section: .banners,
    themeMode: $themeMode
  )
}

#Preview("Settings Window - Appearance") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .auto

  settingsWindowPreview(
    section: .appearance,
    themeMode: $themeMode
  )
}

#Preview("Settings Appearance Section") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .dark

  SettingsAppearanceSection(themeMode: $themeMode)
    .frame(width: 720)
}

#Preview("Settings General Section") {
  let store = SettingsPreviewSupport.makeStore()

  SettingsGeneralSection(
    store: store,
    overview: SettingsGeneralOverviewState(store: store)
  )
  .frame(width: 720)
}

#Preview("Settings Focus Mode Section") {
  SettingsFocusModeSection()
    .frame(width: 720)
}

#Preview("Settings Banners Section") {
  SettingsBannersSection()
    .frame(width: 720)
}

#Preview("Settings Window - Connection") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .auto

  settingsWindowPreview(
    section: .connection,
    themeMode: $themeMode
  )
}

#Preview("Settings Window - Notifications") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .auto

  settingsWindowPreview(
    section: .notifications,
    themeMode: $themeMode
  )
}

#Preview("Settings Window - Voice") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .auto

  settingsWindowPreview(
    section: .voice,
    themeMode: $themeMode
  )
}

#Preview("Settings Window - Authorized Folders") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .auto

  settingsWindowPreview(
    section: .authorizedFolders,
    themeMode: $themeMode
  )
}

#Preview("Settings Window - Database") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .auto

  settingsWindowPreview(
    section: .database,
    themeMode: $themeMode
  )
}

#Preview("Settings Window - Diagnostics") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .auto

  settingsWindowPreview(
    section: .diagnostics,
    themeMode: $themeMode
  )
}

#Preview("Settings Window - Diagnostics Error") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .dark

  settingsWindowPreview(
    section: .diagnostics,
    themeMode: $themeMode,
    store: SettingsPreviewSupport.makeStore(
      previewFeedback: .failure("Failed to read launchd state from the preview daemon.")
    )
  )
}

@MainActor
private func settingsWindowPreview(
  section: SettingsSection,
  themeMode: Binding<HarnessMonitorThemeMode>,
  store: HarnessMonitorStore = SettingsPreviewSupport.makeStore()
) -> some View {
  SettingsWindowPreviewContainer(
    initialSection: section,
    themeMode: themeMode,
    store: store
  )
}

private struct SettingsWindowPreviewContainer: View {
  let initialSection: SettingsSection
  let themeMode: Binding<HarnessMonitorThemeMode>
  let store: HarnessMonitorStore
  let notifications = HarnessMonitorUserNotificationController.preview()
  @State private var selectedSection: SettingsSection

  init(
    initialSection: SettingsSection,
    themeMode: Binding<HarnessMonitorThemeMode>,
    store: HarnessMonitorStore
  ) {
    self.initialSection = initialSection
    self.themeMode = themeMode
    self.store = store
    _selectedSection = State(initialValue: initialSection)
  }

  var body: some View {
    SettingsView(
      store: store,
      notifications: notifications,
      themeMode: themeMode,
      selectedSection: $selectedSection
    )
    .frame(width: 780, height: 560)
  }
}
