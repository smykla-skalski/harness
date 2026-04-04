import SwiftUI

struct PreferencesStatusSection: View {
  let startedAt: String?
  let lastError: String?
  let lastAction: String
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  var body: some View {
    Section("Status") {
      if let startedAt {
        LabeledContent(
          "Started",
          value: formatTimestamp(startedAt, configuration: dateTimeConfiguration)
        )
      }
      if let lastError, !lastError.isEmpty {
        LabeledContent("Latest Error") {
          Text(lastError)
            .foregroundStyle(HarnessMonitorTheme.danger)
        }
      } else if !lastAction.isEmpty {
        LabeledContent("Last Action", value: lastAction)
      } else {
        Text("No recent daemon actions yet.")
          .foregroundStyle(.secondary)
      }
    }
  }
}

#Preview("Preferences Status") {
  Form {
    PreferencesStatusSection(
      startedAt: "2026-03-31T11:42:00Z",
      lastError: nil,
      lastAction: "Reconnect completed successfully."
    )
  }
  .preferencesDetailFormStyle()
  .frame(width: 520)
}

#Preview("Preferences Status Error") {
  Form {
    PreferencesStatusSection(
      startedAt: "2026-03-31T11:42:00Z",
      lastError: "Launch agent removal requires a manual retry.",
      lastAction: ""
    )
  }
  .preferencesDetailFormStyle()
  .frame(width: 520)
}
