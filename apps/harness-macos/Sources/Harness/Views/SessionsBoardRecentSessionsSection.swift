import HarnessKit
import SwiftUI

struct SessionsBoardRecentSessionsSection: View {
  let sessions: [SessionSummary]
  let onSelect: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Recent Sessions")
        .font(.system(.title3, design: .serif, weight: .semibold))
      if sessions.isEmpty {
        Text(
          "No sessions indexed yet. Bring the daemon online or refresh after starting a harness session."
        )
        .font(.system(.body, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessTheme.secondaryInk)
      } else {
        HarnessGlassContainer(spacing: 12) {
          ForEach(sessions.prefix(8)) { session in
            Button {
              onSelect(session.sessionId)
            } label: {
              HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                  .fill(statusColor(for: session.status))
                  .frame(width: 10)
                  .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                  Text(session.context)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(HarnessTheme.ink)
                    .multilineTextAlignment(.leading)
                  Text("\(session.projectName) • \(session.sessionId)")
                    .font(.caption.monospaced())
                    .foregroundStyle(HarnessTheme.secondaryInk)
                }
                Spacer()
                Text(formatTimestamp(session.updatedAt))
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(HarnessTheme.secondaryInk)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(14)
              .background {
                HarnessInteractiveCardBackground(cornerRadius: 18, tint: nil)
              }
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessCard(contentPadding: 16)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.recentSessionsCard)
  }
}
