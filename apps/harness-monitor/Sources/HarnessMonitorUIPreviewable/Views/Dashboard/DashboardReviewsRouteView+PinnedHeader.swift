import HarnessMonitorKit
import SwiftUI

@MainActor
struct DashboardReviewsPinnedSectionHeader: View {
  let itemCount: Int

  @ScaledMetric(relativeTo: .caption)
  private var height = 22.0
  @ScaledMetric(relativeTo: .caption)
  private var horizontalPadding = 8.0

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      Label("Pinned", systemImage: "pin.fill")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Text(verbatim: "\(itemCount)")
        .monospacedDigit()
        .scaledFont(.caption.weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .padding(.horizontal, horizontalPadding)
        .frame(height: height, alignment: .center)
        .harnessControlPillGlass(tint: HarnessMonitorTheme.controlBorder)
        .accessibilityLabel(itemCount == 1 ? "1 pinned review" : "\(itemCount) pinned reviews")
    }
    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsPinnedSectionHeader)
  }
}
