import SwiftUI

public struct MonitorSparklineView: View {
  public let samples: [Double]
  public let outcome: Outcome

  public enum Outcome: Hashable, Sendable {
    case ok
    case error
    case idle
  }

  public init(samples: [Double], outcome: Outcome) {
    self.samples = samples
    self.outcome = outcome
  }

  private var outcomeColor: Color {
    switch outcome {
    case .ok:
      .green
    case .error:
      .red
    case .idle:
      .secondary
    }
  }

  public var body: some View {
    let maxValue = samples.max() ?? 1
    let normalized = samples.map { maxValue > 0 ? $0 / maxValue : 0 }
    HStack(alignment: .bottom, spacing: 1) {
      ForEach(Array(normalized.enumerated()), id: \.offset) { _, value in
        Rectangle()
          .fill(outcomeColor.opacity(0.5))
          .frame(width: 2, height: max(1, CGFloat(value) * 12))
      }
    }
    .frame(width: 40, height: 14, alignment: .bottomTrailing)
    .accessibilityHidden(true)
  }
}

public enum HarnessMonitorSidebarFeatureFlags {
  public static var sparklineEnabled: Bool {
    ProcessInfo.processInfo.environment["HARNESS_FEATURE_SIDEBAR_SPARKLINE"] == "1"
  }
}
