import HarnessMonitorKit
import SwiftUI

struct SidebarSessionRow: View {
  let session: SessionSummary
  let isBookmarked: Bool
  let isSelected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.itemSpacing) {
        Text(session.context)
          .scaledFont(.system(.body, design: .rounded, weight: .semibold))
          .multilineTextAlignment(.leading)
          .lineLimit(2)
        Spacer(minLength: 12)
        if isBookmarked {
          Image(systemName: "bookmark.fill")
            .scaledFont(.caption2)
            .foregroundStyle(isSelected ? HarnessMonitorTheme.onContrast : HarnessMonitorTheme.accent)
            .accessibilityLabel("Bookmarked")
        }
        Text(session.status.title)
          .scaledFont(.caption2.weight(.bold))
          .foregroundStyle(isSelected ? selectedSecondaryTextStyle : statusColor(for: session.status))
          .accessibilityHidden(true)
      }
      Text(session.sessionId)
        .scaledFont(.caption.monospaced())
        .truncationMode(.middle)
        .foregroundStyle(selectedSecondaryTextStyle)
      HStack(spacing: HarnessMonitorTheme.sectionSpacing) {
        labelChip("\(session.metrics.activeAgentCount) active")
        labelChip("\(session.metrics.inProgressTaskCount) moving")
        labelChip(formatTimestamp(session.lastActivityAt))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(isSelected ? HarnessMonitorTheme.onContrast : HarnessMonitorTheme.ink)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func labelChip(_ value: String) -> some View {
    Text(value)
      .scaledFont(.caption.weight(.semibold))
      .lineLimit(1)
      .harnessPillPadding()
      .foregroundStyle(isSelected ? HarnessMonitorTheme.onContrast : HarnessMonitorTheme.ink)
      .harnessContentPill(tint: isSelected ? HarnessMonitorTheme.onContrast : HarnessMonitorTheme.ink)
  }

  private var selectedSecondaryTextStyle: Color {
    isSelected ? HarnessMonitorTheme.onContrast.opacity(0.82) : HarnessMonitorTheme.secondaryInk
  }
}

#Preview("Sidebar row") {
  VStack(spacing: HarnessMonitorTheme.sectionSpacing) {
    SidebarSessionRow(
      session: PreviewFixtures.summary,
      isBookmarked: true,
      isSelected: true
    )
    .padding()
    .background(
      HarnessMonitorTheme.accent,
      in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG)
    )

    SidebarSessionRow(
      session: PreviewFixtures.overflowSessions[3],
      isBookmarked: false,
      isSelected: false
    )
    .padding()
    .background(
      HarnessMonitorTheme.ink.opacity(0.08),
      in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG)
    )
  }
  .padding()
  .frame(width: 360)
}
