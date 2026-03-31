import HarnessKit
import SwiftUI

struct SessionsBoardRecentSessionsSection: View {
  let sessions: [SessionSummary]
  let store: HarnessStore

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      Text("Recent Sessions")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if sessions.isEmpty {
        Text(
          "No sessions indexed yet. Bring the daemon online or refresh after starting a harness session."
        )
        .scaledFont(.system(.body, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessTheme.secondaryInk)
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
          ForEach(sessions.prefix(8)) { session in
            Button {
              store.primeSessionSelection(session.sessionId)
              Task { await store.selectSession(session.sessionId) }
            } label: {
              HStack(alignment: .top, spacing: HarnessTheme.sectionSpacing) {
                RoundedRectangle(cornerRadius: HarnessTheme.cornerRadiusSM, style: .continuous)
                  .fill(statusColor(for: session.status))
                  .frame(width: 8)
                  .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                  HStack(spacing: HarnessTheme.itemSpacing) {
                    Text(session.context)
                      .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
                      .foregroundStyle(HarnessTheme.ink)
                      .multilineTextAlignment(.leading)
                    Text(session.status.title)
                      .scaledFont(.caption2.weight(.bold))
                      .foregroundStyle(statusColor(for: session.status))
                  }
                  Text("\(session.projectName) • \(session.sessionId)")
                    .scaledFont(.caption.monospaced())
                    .truncationMode(.middle)
                    .foregroundStyle(HarnessTheme.secondaryInk)
                }
                Spacer()
                Text(formatTimestamp(session.updatedAt))
                  .scaledFont(.caption.weight(.semibold))
                  .foregroundStyle(HarnessTheme.secondaryInk)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(HarnessTheme.cardPadding)
            }
            .harnessInteractiveCardButtonStyle()
            .contextMenu {
              Button {
                store.primeSessionSelection(session.sessionId)
                Task { await store.selectSession(session.sessionId) }
              } label: {
                Label("Inspect", systemImage: "info.circle")
              }
              Divider()
              Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.sessionId, forType: .string)
              } label: {
                Label("Copy Session ID", systemImage: "doc.on.doc")
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessAccessibility.recentSessionsCard,
      label: "Recent Sessions",
      value: sessions.isEmpty ? "empty" : "\(sessions.count)"
    )
    .accessibilityFrameMarker("\(HarnessAccessibility.recentSessionsCard).frame")
  }
}
