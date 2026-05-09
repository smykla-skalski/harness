import HarnessMonitorKit
import SwiftUI

struct SettingsRecentEventsSection: View {
  let events: [DaemonAuditEvent]
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  var body: some View {
    Section {
      if events.isEmpty {
        Text("No daemon events available yet")
          .foregroundStyle(.secondary)
      } else {
        ForEach(events) { event in
          HStack(spacing: HarnessMonitorTheme.itemSpacing) {
            Image(systemName: eventLevelIcon(event.level))
              .foregroundStyle(eventLevelColor(event.level))
              .scaledFont(.caption)
              .frame(width: 16)
              .accessibilityHidden(true)
            Text(event.message)
              .lineLimit(1)
            Spacer()
            Text(formatTimestamp(event.recordedAt, configuration: dateTimeConfiguration))
              .scaledFont(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
        }
      }
    } header: {
      Text("Recent Events")
        .harnessNativeFormSectionHeader()
    }
  }

  private func eventLevelIcon(_ level: String) -> String {
    switch level {
    case "trace": "circle.dotted"
    case "debug": "ant.fill"
    case "info": "info.circle.fill"
    case "warn": "exclamationmark.triangle.fill"
    case "error": "exclamationmark.octagon.fill"
    default: "questionmark.circle"
    }
  }

  private func eventLevelColor(_ level: String) -> Color {
    switch level {
    case "trace": .gray
    case "debug": .secondary
    case "info": .blue
    case "warn": HarnessMonitorTheme.caution
    case "error": HarnessMonitorTheme.danger
    default: .secondary
    }
  }
}
