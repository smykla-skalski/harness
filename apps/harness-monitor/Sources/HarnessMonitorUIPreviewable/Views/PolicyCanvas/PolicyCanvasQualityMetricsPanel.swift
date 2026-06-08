import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Floating panel that lists every deterministic graph-quality counter for the
/// laid-out graph, each colored by severity (error red, warning amber, clean
/// muted). It is the visual companion to the regression gates: the same counts
/// the gate budgets, shown live as the lab routes a sample. Toggled from the lab
/// toolbar and off by default, so it only appears when a developer asks for it.
struct PolicyCanvasQualityMetricsPanel: View {
  let report: PolicyCanvasGraphQualityReport
  @Environment(\.colorScheme)
  private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      VStack(alignment: .leading, spacing: 3) {
        ForEach(report.headlines, id: \.label) { headline in
          row(headline)
        }
        Divider()
          .padding(.vertical, 3)
        footer
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 8)
    }
    .frame(width: 196)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(PolicyCanvasVisualStyle.floatingControlBackground(colorScheme))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(
          PolicyCanvasVisualStyle.floatingControlBorder(colorScheme),
          lineWidth: PolicyCanvasVisualStyle.floatingControlBorderLineWidth(colorScheme)
        )
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Graph quality metrics")
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasQualityMetrics)
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: "ruler")
        .imageScale(.small)
        .foregroundStyle(.secondary)
      Text("Graph quality")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
      Spacer(minLength: 0)
      summaryBadge
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(minHeight: PolicyCanvasVisualStyle.floatingControlMinHeight)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Graph quality")
    .accessibilityValue(
      report.errorCount == 0 ? "No errors" : "\(report.errorCount) errors"
    )
  }

  private var summaryBadge: some View {
    Text(report.errorCount == 0 ? "clean" : "\(report.errorCount)")
      .scaledFont(.caption2.weight(.bold))
      .monospacedDigit()
      .foregroundStyle(
        report.errorCount == 0
          ? PolicyCanvasVisualStyle.secondaryText
          : PolicyCanvasVisualStyle.blockedTint
      )
  }

  private func row(_ headline: PolicyCanvasGraphQualityReport.Headline) -> some View {
    HStack(spacing: 8) {
      Text(headline.label)
        .scaledFont(.caption2)
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        .lineLimit(1)
      Spacer(minLength: 4)
      Text("\(headline.value)")
        .scaledFont(.caption2.weight(headline.value > 0 ? .bold : .regular))
        .monospacedDigit()
        .foregroundStyle(color(for: headline))
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(headline.label)
    .accessibilityValue("\(headline.value)")
  }

  private var footer: some View {
    let maxEdge = Int(report.edgeLengths.maxLength.rounded())
    let occupancy = Int((report.bounds.nodeOccupancyRatio * 100).rounded())
    return VStack(alignment: .leading, spacing: 2) {
      Text("max edge \(maxEdge) · bends \(report.edgeLengths.totalBends)")
      Text("occupancy \(occupancy)%")
    }
    .scaledFont(.caption2)
    .foregroundStyle(PolicyCanvasVisualStyle.secondaryText.opacity(0.8))
    .monospacedDigit()
    .accessibilityElement(children: .combine)
  }

  private func color(for headline: PolicyCanvasGraphQualityReport.Headline) -> Color {
    guard headline.value > 0 else {
      return PolicyCanvasVisualStyle.secondaryText.opacity(0.5)
    }
    switch headline.severity {
    case .error: return PolicyCanvasVisualStyle.blockedTint
    case .warning: return PolicyCanvasVisualStyle.warningTint
    }
  }
}
