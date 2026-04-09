import HarnessMonitorKit
import SwiftUI

struct SidebarSessionRow: View {
  let session: SessionSummary
  let isBookmarked: Bool
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.sectionSpacing) {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .fill(statusColor(for: session.status))
        .frame(width: 8)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        HStack(alignment: .top, spacing: HarnessMonitorTheme.itemSpacing) {
          Text(session.displayTitle)
            .scaledFont(.system(.body, design: .rounded, weight: .semibold))
            .italic(session.title.isEmpty)
            .foregroundStyle(session.title.isEmpty ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 12)
          if isBookmarked {
            Image(systemName: "bookmark.fill")
              .scaledFont(.caption2)
              .foregroundStyle(.secondary)
              .accessibilityLabel("Bookmarked")
          }
          Text(session.status.title)
            .scaledFont(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        Text(session.sessionId)
          .scaledFont(.caption.monospaced())
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
        HStack(spacing: HarnessMonitorTheme.sectionSpacing) {
          footerLabel("\(session.metrics.activeAgentCount) active")
          footerLabel("\(session.metrics.inProgressTaskCount) moving")
          Spacer(minLength: 0)
          Text(formatTimestamp(session.lastActivityAt, configuration: dateTimeConfiguration))
            .scaledFont(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func footerLabel(_ value: String) -> some View {
    Text(value)
      .scaledFont(.caption.weight(.medium))
      .lineLimit(1)
      .foregroundStyle(.secondary)
  }
}

#Preview("Sidebar row") {
  VStack(spacing: HarnessMonitorTheme.sectionSpacing) {
    SidebarSessionRow(
      session: PreviewFixtures.summary,
      isBookmarked: true
    )
    .padding()

    SidebarSessionRow(
      session: PreviewFixtures.overflowSessions[3],
      isBookmarked: false
    )
    .padding()
  }
  .padding()
  .frame(width: 360)
}
