import HarnessMonitorKit
import SwiftUI

/// Section header above the pinned-PR group at the top of the Reviews list.
///
/// Visually carries the same `.accent` family as the pinned rows below
/// (left stripe + soft tint on each row), so the header reads as the cap of
/// a connected accent stack rather than as another anonymous group label
/// that competes with the repository section headers.
@MainActor
struct DashboardReviewsPinnedSectionHeader: View {
  let itemCount: Int

  @ScaledMetric(relativeTo: .caption)
  private var countDiameter = 18.0

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      Label("Pinned", systemImage: "pin.fill")
        .scaledFont(.caption.weight(.bold))
        .foregroundStyle(HarnessMonitorTheme.accent)
        .labelStyle(.titleAndIcon)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Text(verbatim: "\(itemCount)")
        .monospacedDigit()
        .scaledFont(.caption2.weight(.bold))
        .lineLimit(1)
        .foregroundStyle(HarnessMonitorTheme.accent)
        .frame(minWidth: countDiameter, minHeight: countDiameter)
        .padding(.horizontal, 4)
        .background(
          Capsule(style: .continuous)
            .fill(HarnessMonitorTheme.accent.opacity(0.18))
        )
        .accessibilityLabel(itemCount == 1 ? "1 pinned review" : "\(itemCount) pinned reviews")
    }
    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsPinnedSectionHeader)
  }
}
