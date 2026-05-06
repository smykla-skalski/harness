import SwiftUI

struct SettingsStatusSection: View {
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
