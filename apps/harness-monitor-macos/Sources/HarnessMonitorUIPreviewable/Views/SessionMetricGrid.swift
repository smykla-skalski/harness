import HarnessMonitorKit
import SwiftUI

struct SessionMetricGrid: View {
  let metrics: SessionMetrics
  @ScaledMetric(relativeTo: .body)
  private var badgeMinWidth: CGFloat = 28
  @ScaledMetric(relativeTo: .body)
  private var badgePaddingH: CGFloat = 8
  @ScaledMetric(relativeTo: .body)
  private var badgePaddingV: CGFloat = 4
  var body: some View {
    HarnessMonitorAdaptiveGridLayout(
      minimumColumnWidth: 130,
      maximumColumns: 5,
      spacing: HarnessMonitorTheme.sectionSpacing
    ) {
      metricCard(
        singular: "Agent",
        plural: "Agents",
        count: metrics.agentCount,
        tint: HarnessMonitorTheme.accent
      )
      metricCard(
        singular: "Active",
        plural: "Active",
        count: metrics.activeAgentCount,
        tint: HarnessMonitorTheme.success
      )
      metricCard(
        singular: "In Flight",
        plural: "In Flight",
        count: metrics.inProgressTaskCount,
        tint: HarnessMonitorTheme.warmAccent
      )
      metricCard(
        singular: "Blocked",
        plural: "Blocked",
        count: metrics.blockedTaskCount,
        tint: HarnessMonitorTheme.danger
      )
      metricCard(
        singular: "Awaiting Review",
        plural: "Awaiting Review",
        count: metrics.awaitingReviewAgentCount,
        tint: HarnessMonitorTheme.caution,
        identifier: HarnessMonitorAccessibility.metricAwaitingReviewAgent
      )
      metricCard(
        singular: "To Review",
        plural: "To Review",
        count: metrics.awaitingReviewTaskCount,
        tint: HarnessMonitorTheme.caution,
        identifier: HarnessMonitorAccessibility.metricAwaitingReviewTask
      )
      metricCard(
        singular: "In Review",
        plural: "In Review",
        count: metrics.inReviewTaskCount,
        tint: HarnessMonitorTheme.accent,
        identifier: HarnessMonitorAccessibility.metricInReviewTask
      )
      metricCard(
        singular: "Arbitration",
        plural: "Arbitration",
        count: metrics.arbitrationTaskCount,
        tint: HarnessMonitorTheme.danger,
        identifier: HarnessMonitorAccessibility.metricArbitrationTask
      )
      metricCard(
        singular: "Completed",
        plural: "Completed",
        count: metrics.completedTaskCount,
        tint: HarnessMonitorTheme.ink
      )
    }
  }

  private func metricCard(
    singular: String,
    plural: String,
    count: Int,
    tint: Color,
    identifier: String? = nil
  ) -> some View {
    let title = count == 1 ? singular : plural
    return HStack(alignment: .center, spacing: HarnessMonitorTheme.sectionSpacing) {
      knockoutBadge(value: "\(count)", tint: tint)
      Text(title.uppercased())
        .scaledFont(.caption.weight(.semibold))
        .tracking(HarnessMonitorTheme.uppercaseTracking)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, HarnessMonitorTheme.itemSpacing)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(identifier ?? "")
  }

  private func knockoutBadge(value: String, tint: Color) -> some View {
    Text(value)
      .scaledFont(.system(.body, design: .rounded, weight: .heavy))
      .monospacedDigit()
      .padding(.horizontal, badgePaddingH)
      .padding(.vertical, badgePaddingV)
      .frame(minWidth: badgeMinWidth)
      .foregroundStyle(HarnessMonitorTheme.onContrast)
      .background {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(tint)
      }
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(tint.opacity(0.16), lineWidth: 1)
      }
      .accessibilityLabel(value)
      .accessibilityValue("")
  }
}

#Preview("Metrics") {
  SessionMetricGrid(metrics: PreviewFixtures.summary.metrics)
    .padding()
    .frame(width: 960)
}
