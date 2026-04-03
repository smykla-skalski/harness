import HarnessMonitorKit
import SwiftUI

struct SessionMetricGrid: View {
  let metrics: SessionMetrics
  @ScaledMetric(relativeTo: .caption)
  private var barWidth: CGFloat = 8
  @ScaledMetric(relativeTo: .title)
  private var cardMinHeight: CGFloat = 60

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
    HStack(alignment: .top, spacing: HarnessMonitorTheme.sectionSpacing) {
      RoundedRectangle(cornerRadius: 999, style: .continuous)
        .fill(tint)
        .frame(width: barWidth)
        .frame(minHeight: cardMinHeight)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        Text(title.uppercased())
          .scaledFont(.caption.weight(.semibold))
          .tracking(HarnessMonitorTheme.uppercaseTracking)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text(value)
          .scaledFont(.system(.title, design: .rounded, weight: .heavy))
          .foregroundStyle(tint)
          .contentTransition(.numericText())
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, HarnessMonitorTheme.itemSpacing)
  }
}

#Preview("Metrics") {
  SessionMetricGrid(metrics: PreviewFixtures.summary.metrics)
    .padding()
    .frame(width: 960)
}
