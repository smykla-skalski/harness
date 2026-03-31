import HarnessKit
import SwiftUI

struct PreferencesRecentEventsSection: View {
  let events: [DaemonAuditEvent]

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
                .font(.caption.bold())
                .foregroundStyle(
                  eventLevelColor(event.level)
                )
              Spacer()
              Text(formatTimestamp(event.recordedAt))
                .font(.caption.monospaced())
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
    case "warn": HarnessTheme.caution
    case "error": HarnessTheme.danger
    default: .primary
    }
  }
}
