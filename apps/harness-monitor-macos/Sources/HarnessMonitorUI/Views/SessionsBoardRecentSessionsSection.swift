import HarnessMonitorKit
import SwiftUI

struct SessionsBoardRecentSessionsSection: View {
  let store: HarnessMonitorStore
  let sessions: [SessionSummary]
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Recent Sessions")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if sessions.isEmpty {
        Text(
          "No sessions indexed yet. Start a harness session and refresh to see it here."
        )
        .scaledFont(.system(.body, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
            ForEach(sessions.prefix(8)) { session in
              DashboardSessionCard(
                store: store,
                session: session
              )
            }
          }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.recentSessionsCard,
      label: "Recent Sessions",
      value: sessions.isEmpty ? "empty" : "\(sessions.count)"
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.recentSessionsCard).frame")
  }
}

private struct DashboardSessionCard: View {
  let store: HarnessMonitorStore
  let session: SessionSummary
  @State private var isHovered = false
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  private var presentation: HarnessMonitorStore.SessionSummaryPresentation {
    store.sessionSummaryPresentation(for: session)
  }

  var body: some View {
    Button {
      Task { await store.selectSession(session.sessionId) }
    } label: {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.sectionSpacing) {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
          .fill(statusColor(for: presentation.statusTone))
          .frame(width: 8)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .top, spacing: HarnessMonitorTheme.itemSpacing) {
            Text(session.displayTitle)
              .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
              .italic(session.title.isEmpty)
              .foregroundStyle(
                session.title.isEmpty
                  ? HarnessMonitorTheme.tertiaryInk
                  : HarnessMonitorTheme.ink
               )
               .multilineTextAlignment(.leading)
             Spacer(minLength: 12)
             Text(presentation.statusText)
               .scaledFont(.caption2.weight(.bold))
               .foregroundStyle(statusColor(for: presentation.statusTone))
           }
           HStack(spacing: HarnessMonitorTheme.sectionSpacing) {
             Text(sessionMetadata(session))
              .scaledFont(.caption.monospaced())
              .truncationMode(.middle)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            Spacer(minLength: 0)
            Text(formatTimestamp(session.lastActivityAt, configuration: dateTimeConfiguration))
              .scaledFont(.caption.weight(.semibold))
              .foregroundStyle(
                isHovered
                  ? HarnessMonitorTheme.secondaryInk
                  : HarnessMonitorTheme.ink.opacity(0.35)
              )
              .animation(.easeInOut(duration: 0.15), value: isHovered)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(HarnessMonitorTheme.cardPadding)
    }
    .harnessInteractiveCardButtonStyle()
    .onHover { isHovered = $0 }
    .contextMenu {
      Button {
        Task { await store.selectSession(session.sessionId) }
      } label: {
        Label("Inspect", systemImage: "info.circle")
      }
      Divider()
      Button {
        HarnessMonitorClipboard.copy(session.title)
      } label: {
        Label("Copy Title", systemImage: "doc.on.doc")
      }
      .disabled(session.title.isEmpty)
      Button {
        HarnessMonitorClipboard.copy(session.sessionId)
      } label: {
        Label("Copy Session ID", systemImage: "doc.on.doc")
      }
    }
  }
}

private func sessionMetadata(_ session: SessionSummary) -> String {
  if session.isWorktree {
    return "\(session.projectName) • \(session.checkoutDisplayName) • \(session.sessionId)"
  }
  return "\(session.projectName) • \(session.sessionId)"
}

#Preview("Recent sessions") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)

  SessionsBoardRecentSessionsSection(
    store: store,
    sessions: PreviewFixtures.overflowSessions
  )
  .padding()
  .frame(width: 960)
}
