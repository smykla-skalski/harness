import HarnessKit
import SwiftUI

struct PreferencesRecentEventsCard: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  let events: [DaemonAuditEvent]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Recent Events")
        .font(.system(.title3, weight: .semibold))

      if events.isEmpty {
        Text("No daemon events available from the live diagnostics stream yet.")
          .font(.system(.body, design: .rounded, weight: .medium))
          .foregroundStyle(HarnessTheme.secondaryInk)
      } else {
        HarnessGlassContainer(spacing: 12) {
          ForEach(events) { event in
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(event.level.uppercased())
                  .font(.caption.bold())
                  .foregroundStyle(eventLevelColor(event.level))
                Spacer()
                Text(formatTimestamp(event.recordedAt))
                  .font(.caption.monospaced())
                  .foregroundStyle(HarnessTheme.secondaryInk)
              }
              Text(event.message)
                .font(.system(.body, design: .rounded, weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background {
              HarnessInsetPanelBackground(
                cornerRadius: 18,
                fillOpacity: 0.05,
                strokeOpacity: 0.10
              )
            }
            .accessibilityElement(children: .combine)
          }
        }
      }
    }
    .harnessCard()
  }

  private func eventLevelColor(_ level: String) -> Color {
    switch level {
    case "warn": HarnessTheme.caution
    case "error": HarnessTheme.danger
    default: HarnessTheme.accent(for: themeStyle)
    }
  }
}
