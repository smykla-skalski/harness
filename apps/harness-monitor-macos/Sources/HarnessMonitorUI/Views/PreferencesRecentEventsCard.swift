import HarnessMonitorKit
import SwiftUI

struct PreferencesRecentEventsSection: View {
  let events: [DaemonAuditEvent]
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  var body: some View {
    Section("Recent Events") {
      if events.isEmpty {
        Text("No daemon events available yet.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(events) { event in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(event.level.uppercased())
                .scaledFont(.caption.bold())
                .tracking(HarnessMonitorTheme.uppercaseTracking)
                .foregroundStyle(
                  eventLevelColor(event.level)
                )
              Spacer()
              Text(formatTimestamp(event.recordedAt, configuration: dateTimeConfiguration))
                .scaledFont(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            Text(event.message)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private func eventLevelColor(_ level: String) -> Color {
    switch level {
    case "warn": HarnessMonitorTheme.caution
    case "error": HarnessMonitorTheme.danger
    default: .primary
    }
  }
}

#Preview("Preferences Recent Events") {
  Form {
    PreferencesRecentEventsSection(events: PreferencesPreviewSupport.recentEvents)
  }
  .preferencesDetailFormStyle()
  .frame(width: 560)
}

#Preview("Preferences Recent Events Empty") {
  Form {
    PreferencesRecentEventsSection(events: [])
  }
  .preferencesDetailFormStyle()
  .frame(width: 560)
}
