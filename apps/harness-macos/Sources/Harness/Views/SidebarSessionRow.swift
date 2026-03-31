import HarnessKit
import SwiftUI

struct SidebarSessionRow: View {
  let session: SessionSummary
  let store: HarnessStore
  let isSelected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      HStack(alignment: .top, spacing: HarnessTheme.itemSpacing) {
        Text(session.context)
          .scaledFont(.system(.body, design: .rounded, weight: .semibold))
          .multilineTextAlignment(.leading)
          .lineLimit(2)
        Spacer(minLength: 12)
        if store.isBookmarked(sessionId: session.sessionId) {
          Image(systemName: "bookmark.fill")
            .scaledFont(.caption2)
            .foregroundStyle(isSelected ? HarnessTheme.onContrast : HarnessTheme.accent)
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
      HStack(spacing: HarnessTheme.sectionSpacing) {
        labelChip("\(session.metrics.activeAgentCount) active")
        labelChip("\(session.metrics.inProgressTaskCount) moving")
        labelChip(formatTimestamp(session.lastActivityAt))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(isSelected ? HarnessTheme.onContrast : HarnessTheme.ink)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func labelChip(_ value: String) -> some View {
    Text(value)
      .scaledFont(.caption.weight(.semibold))
      .lineLimit(1)
      .harnessPillPadding()
      .foregroundStyle(isSelected ? HarnessTheme.onContrast : HarnessTheme.ink)
      .harnessInfoPill(tint: isSelected ? HarnessTheme.onContrast : HarnessTheme.ink)
  }

  private var selectedSecondaryTextStyle: Color {
    isSelected ? HarnessTheme.onContrast.opacity(0.82) : HarnessTheme.secondaryInk
  }
}
