import HarnessMonitorKit
import SwiftUI

/// Section header above the pinned-PR group at the top of the Reviews list.
///
/// Visually carries the same `.accent` family as the pinned rows below,
/// so the header reads as the cap of a connected accent stack rather than as
/// another anonymous group label that competes with the repository headers.
@MainActor
struct DashboardReviewsPinnedSectionHeader: View {
  let itemCount: Int

  var body: some View {
    DashboardReviewsSectionHeaderChrome(isPinnedFamily: true) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
        Label("Pinned", systemImage: "pin.fill")
          .scaledFont(.caption.weight(.bold))
          .foregroundStyle(HarnessMonitorTheme.accent)
          .labelStyle(.titleAndIcon)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Text(verbatim: "\(itemCount)")
          .monospacedDigit()
          .scaledFont(.caption.weight(.semibold))
          .lineLimit(1)
          .foregroundStyle(HarnessMonitorTheme.accent)
          .accessibilityLabel(itemCount == 1 ? "1 pinned review" : "\(itemCount) pinned reviews")
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsPinnedSectionHeader)
    }
  }
}
