import SwiftUI

#Preview("Settings Status") {
  Form {
    SettingsStatusSection(
      startedAt: "2026-03-31T11:42:00Z"
    )
  }
  .settingsDetailFormStyle()
  .frame(width: 520)
}

#Preview("Settings Status Idle") {
  Form {
    SettingsStatusSection(
      startedAt: nil
    )
  }
  .settingsDetailFormStyle()
  .frame(width: 520)
}
