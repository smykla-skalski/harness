import SwiftUI

struct PreferencesStatusSection: View {
  let startedAt: String?
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  var body: some View {
    Section("Status") {
      if let startedAt {
        LabeledContent(
          "Started",
          value: formatTimestamp(startedAt, configuration: dateTimeConfiguration)
        )
      } else {
        Text("Daemon not started.")
          .foregroundStyle(.secondary)
      }
    }
  }
}

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
