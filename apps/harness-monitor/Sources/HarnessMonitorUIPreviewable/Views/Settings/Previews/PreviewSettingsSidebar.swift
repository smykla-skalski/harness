import SwiftUI

#Preview("Settings Sidebar") {
  @Previewable @State var selection: SettingsSection = .diagnostics

  SettingsSidebarList(selection: $selection)
    .frame(width: 220, height: 220)
}
