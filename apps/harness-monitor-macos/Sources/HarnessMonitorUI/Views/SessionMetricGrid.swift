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
        title: "Agents",
        value: "\(metrics.agentCount)",
        tint: HarnessMonitorTheme.accent
      )
      metricCard(
        title: "Active",
        value: "\(metrics.activeAgentCount)",
        tint: HarnessMonitorTheme.success
      )
      metricCard(
        title: "In Flight",
        value: "\(metrics.inProgressTaskCount)",
        tint: HarnessMonitorTheme.warmAccent
      )
      metricCard(
        title: "Blocked",
        value: "\(metrics.blockedTaskCount)",
        tint: HarnessMonitorTheme.danger
      )
      metricCard(
        title: "Completed",
        value: "\(metrics.completedTaskCount)",
        tint: HarnessMonitorTheme.ink
      )
    }
  }

  private func metricCard(title: String, value: String, tint: Color) -> some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.sectionSpacing) {
      knockoutBadge(value: value, tint: tint)
      Text(title.uppercased())
        .scaledFont(.caption.weight(.semibold))
        .tracking(HarnessMonitorTheme.uppercaseTracking)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, HarnessMonitorTheme.itemSpacing)
  }

  private func knockoutBadge(value: String, tint: Color) -> some View {
    Text(value)
      .scaledFont(.system(.body, design: .rounded, weight: .heavy))
      .monospacedDigit()
      .padding(.horizontal, badgePaddingH)
      .padding(.vertical, badgePaddingV)
      .frame(minWidth: badgeMinWidth)
      .foregroundStyle(.clear)
      .background {
        ZStack {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint)
          Text(value)
            .scaledFont(.system(.body, design: .rounded, weight: .heavy))
            .monospacedDigit()
            .contentTransition(.numericText())
            .blendMode(.destinationOut)
        }
        .compositingGroup()
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
