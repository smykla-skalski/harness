import HarnessMonitorKit
import SwiftUI

#Preview("Metrics") {
  SessionMetricGrid(metrics: PreviewFixtures.summary.metrics)
    .padding()
    .frame(width: 960)
}
