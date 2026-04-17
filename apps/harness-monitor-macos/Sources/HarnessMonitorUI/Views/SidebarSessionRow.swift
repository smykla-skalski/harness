import HarnessMonitorKit
import SwiftUI

struct SidebarSessionRow: View {
  let session: SessionSummary
  let presentation: HarnessMonitorStore.SessionSummaryPresentation
  let isBookmarked: Bool
  let lastActivityText: String
  let fontScale: CGFloat

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.sectionSpacing) {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .fill(statusColor(for: presentation.statusTone))
        .frame(width: 8)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        HStack(alignment: .top, spacing: HarnessMonitorTheme.itemSpacing) {
          Text(verbatim: session.displayTitle)
            .font(scaled(.system(.body, design: .rounded, weight: .semibold)))
            .italic(session.title.isEmpty)
            .foregroundStyle(session.title.isEmpty ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 12)
          if isBookmarked {
            Image(systemName: "bookmark.fill")
              .font(scaled(.caption2))
              .foregroundStyle(.secondary)
              .accessibilityLabel("Bookmarked")
          }
          Text(verbatim: presentation.statusText)
            .font(scaled(.caption2.weight(.bold)))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        Text(verbatim: session.sessionId)
          .font(scaled(.caption.monospaced()))
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
        HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
          HStack(spacing: HarnessMonitorTheme.itemSpacing) {
            footerStatBadge(
              presentation.agentStat,
              identifier: HarnessMonitorAccessibility.sessionRowAgentStat(session.sessionId)
            )
            footerStatBadge(
              presentation.taskStat,
              identifier: HarnessMonitorAccessibility.sessionRowTaskStat(session.sessionId)
            )
          }
          .fixedSize(horizontal: true, vertical: false)
          .accessibilityFrameMarker(
            HarnessMonitorAccessibility.sessionRowStatsFrame(session.sessionId)
          )
          Spacer(minLength: HarnessMonitorTheme.spacingXS)
          Text(verbatim: lastActivityText)
            .font(scaled(.caption.weight(.medium)))
            .lineLimit(1)
            .truncationMode(.head)
            .foregroundStyle(.secondary)
            .accessibilityFrameMarker(
              HarnessMonitorAccessibility.sessionRowLastActivityFrame(session.sessionId)
            )
        }
        .frame(maxWidth: .infinity)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func footerStatBadge(
    _ stat: HarnessMonitorStore.SessionSummaryPresentation.SidebarStatPresentation,
    identifier: String
  ) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Image(systemName: stat.symbolName)
        .font(scaled(.caption.weight(.medium)))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(verbatim: stat.valueText)
        .font(scaled(.caption.monospacedDigit().weight(.medium)))
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .help(stat.helpText)
    .accessibilityTestProbe(
      identifier,
      label: stat.symbolName,
      value: stat.helpText
    )
  }

  private func scaled(_ font: Font) -> Font {
    HarnessMonitorTextSize.scaledFont(font, by: fontScale)
  }
}

#Preview("Sidebar row") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)

  VStack(spacing: HarnessMonitorTheme.sectionSpacing) {
    SidebarSessionRow(
      session: PreviewFixtures.summary,
      presentation: store.sessionSummaryPresentation(for: PreviewFixtures.summary),
      isBookmarked: true,
      lastActivityText: formatTimestamp(PreviewFixtures.summary.lastActivityAt),
      fontScale: 1
    )
    .padding()

    let overflowSession = PreviewFixtures.overflowSessions[3]
    SidebarSessionRow(
      session: overflowSession,
      presentation: store.sessionSummaryPresentation(for: overflowSession),
      isBookmarked: false,
      lastActivityText: formatTimestamp(overflowSession.lastActivityAt),
      fontScale: 1
    )
    .padding()
  }
  .padding()
  .frame(width: 360)
}
