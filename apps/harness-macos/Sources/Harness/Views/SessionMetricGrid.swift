import HarnessKit
import SwiftUI

struct SessionMetricGrid: View {
  let metrics: SessionMetrics
  @ScaledMetric(relativeTo: .caption)
  private var barWidth: CGFloat = 8
  @ScaledMetric(relativeTo: .title)
  private var cardMinHeight: CGFloat = 60

  var body: some View {
    HarnessAdaptiveGridLayout(
      minimumColumnWidth: 130,
      maximumColumns: 5,
      spacing: HarnessTheme.sectionSpacing
    ) {
      metricCard(
        title: "Agents",
        value: "\(metrics.agentCount)",
        tint: HarnessTheme.accent
      )
      metricCard(
        title: "Active",
        value: "\(metrics.activeAgentCount)",
        tint: HarnessTheme.success
      )
      metricCard(
        title: "In Flight",
        value: "\(metrics.inProgressTaskCount)",
        tint: HarnessTheme.warmAccent
      )
      metricCard(
        title: "Blocked",
        value: "\(metrics.blockedTaskCount)",
        tint: HarnessTheme.danger
      )
      metricCard(
        title: "Completed",
        value: "\(metrics.completedTaskCount)",
        tint: HarnessTheme.ink
      )
    }
  }

  private func metricCard(title: String, value: String, tint: Color) -> some View {
    HStack(alignment: .top, spacing: HarnessTheme.sectionSpacing) {
      RoundedRectangle(cornerRadius: 999, style: .continuous)
        .fill(tint)
        .frame(width: barWidth)
        .frame(minHeight: cardMinHeight)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
        Text(title.uppercased())
          .scaledFont(.caption.weight(.semibold))
          .tracking(HarnessTheme.uppercaseTracking)
          .foregroundStyle(HarnessTheme.secondaryInk)
        Text(value)
          .scaledFont(.system(.title, design: .rounded, weight: .heavy))
          .foregroundStyle(tint)
          .contentTransition(.numericText())
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, HarnessTheme.itemSpacing)
  }
}

#Preview("Metrics") {
  SessionMetricGrid(metrics: PreviewFixtures.summary.metrics)
    .padding()
    .frame(width: 960)
}
