import HarnessMonitorKit
import SwiftUI

/// Live-tick view showing last snapshot id, tick latency (rolling p50/p95), active observer
/// count, and quarantined rules. `chrome: true` (default) wraps the metrics in a card surface;
/// `chrome: false` is used inside the inspector column where the column itself provides the
/// surface and stacking another card would double-paint glass on glass.
public struct DecisionsLiveTickView: View {
  private let snapshot: DecisionLiveTickSnapshot
  private let chrome: Bool

  public init(snapshot: DecisionLiveTickSnapshot = .placeholder, chrome: Bool = true) {
    self.snapshot = snapshot
    self.chrome = chrome
  }

  public var body: some View {
    let metrics = VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Grid(alignment: .leading, horizontalSpacing: HarnessMonitorTheme.spacingLG) {
        GridRow {
          LiveTickMetricCell(title: "Last Snapshot", value: snapshot.lastSnapshotID ?? "n/a")
          LiveTickMetricCell(title: "Observers", value: "\(snapshot.activeObserverCount)")
        }
        GridRow {
          LiveTickMetricCell(title: "Latency p50", value: latencyLabel(snapshot.tickLatencyP50Ms))
          LiveTickMetricCell(title: "Latency p95", value: latencyLabel(snapshot.tickLatencyP95Ms))
        }
      }
      if snapshot.quarantinedRuleIDs.isEmpty {
        Text("No quarantined rules.")
          .scaledFont(.callout)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          Text("Quarantined Rules")
            .scaledFont(.caption.bold())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          FlowQuarantinedRules(ruleIDs: snapshot.quarantinedRuleIDs)
        }
      }
    }

    return Group {
      if chrome {
        metrics
          .padding(HarnessMonitorTheme.cardPadding)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background {
            RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
              .fill(HarnessMonitorTheme.ink.opacity(0.04))
          }
          .overlay {
            RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
              .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.32), lineWidth: 1)
          }
      } else {
        metrics
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsLiveTick)
  }

  private func latencyLabel(_ latency: Double) -> String {
    guard latency > 0 else {
      return "n/a"
    }
    return "\(Int(latency.rounded()))ms"
  }
}

private struct LiveTickMetricCell: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(value)
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct FlowQuarantinedRules: View {
  let ruleIDs: [String]

  var body: some View {
    ViewThatFits(in: .vertical) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        ForEach(ruleIDs, id: \.self) { ruleID in
          ruleBadge(ruleID)
        }
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        ForEach(ruleIDs, id: \.self) { ruleID in
          ruleBadge(ruleID)
        }
      }
    }
  }

  private func ruleBadge(_ ruleID: String) -> some View {
    Text(ruleID)
      .scaledFont(.caption.monospaced())
      .foregroundStyle(HarnessMonitorTheme.caution)
      .harnessPillPadding()
      .harnessControlPill(tint: HarnessMonitorTheme.caution)
  }
}

#Preview("Decisions Live Tick — empty") {
  DecisionsLiveTickView()
    .frame(width: 420, height: 100)
}

#Preview("Decisions Live Tick — populated") {
  DecisionsLiveTickView(
    snapshot: DecisionLiveTickSnapshot(
      lastSnapshotID: "snap-2026-04-23T09:14:00Z",
      tickLatencyP50Ms: 128,
      tickLatencyP95Ms: 342,
      activeObserverCount: 4,
      quarantinedRuleIDs: ["stuck-agent", "task-starvation"]
    )
  )
  .frame(width: 420, height: 160)
}
