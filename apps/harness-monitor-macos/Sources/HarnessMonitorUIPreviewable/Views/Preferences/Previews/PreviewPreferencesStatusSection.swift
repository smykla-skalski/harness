import SwiftUI

#Preview("Preferences Status") {
  Form {
    PreferencesStatusSection(
      startedAt: "2026-03-31T11:42:00Z"
    )
  }
  .preferencesDetailFormStyle()
  .frame(width: 520)
}

#Preview("Preferences Status Idle") {
  Form {
    PreferencesStatusSection(
      startedAt: nil
    )
  }
  .preferencesDetailFormStyle()
  .frame(width: 520)
}
