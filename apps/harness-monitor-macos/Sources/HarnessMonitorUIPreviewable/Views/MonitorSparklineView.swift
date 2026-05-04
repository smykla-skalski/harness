import SwiftUI

// Single-draw sparkline: one Canvas leaf, one Path containing all bars,
// one fill call. Replaces a per-bar Rectangle/ForEach shape that allocated
// one SwiftUI view leaf per sample. Feature-flag-gated and ships with
// empty samples until a per-session metric pipeline lands; the empty case
// renders nothing visible and is a safe no-op.
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
    Canvas { context, size in
      guard !samples.isEmpty else { return }
      let maxValue = samples.max() ?? 0
      guard maxValue > 0 else { return }
      let barWidth: CGFloat = 2
      let gap: CGFloat = 1
      let stride = barWidth + gap
      var path = Path()
      for (index, value) in samples.enumerated() {
        let x = CGFloat(index) * stride
        guard x + barWidth <= size.width else { break }
        let normalized = CGFloat(value / maxValue)
        let height = max(1, normalized * size.height)
        let y = size.height - height
        path.addRect(CGRect(x: x, y: y, width: barWidth, height: height))
      }
      context.fill(path, with: .color(outcomeColor.opacity(0.5)))
    }
    .frame(width: 40, height: 12)
    .accessibilityHidden(true)
  }
}

public enum HarnessMonitorSidebarFeatureFlags {
  public static var sparklineEnabled: Bool {
    ProcessInfo.processInfo.environment["HARNESS_FEATURE_SIDEBAR_SPARKLINE"] == "1"
  }
}
