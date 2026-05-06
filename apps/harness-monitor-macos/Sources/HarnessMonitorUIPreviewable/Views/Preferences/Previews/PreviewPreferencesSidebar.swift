import SwiftUI

#Preview("Preferences Sidebar") {
  @Previewable @State var selection: PreferencesSection = .diagnostics

  PreferencesSidebarList(selection: $selection)
    .frame(width: 220, height: 220)
}
