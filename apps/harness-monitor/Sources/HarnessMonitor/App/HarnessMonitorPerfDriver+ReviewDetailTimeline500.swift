import Foundation
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

@MainActor
extension HarnessMonitorPerfDriver {
  /// Audits the Reviews detail-pane timeline scroll path against
  /// the perf budgets declared in `HarnessMonitorPerfScenarios.json`
  /// (`review-detail-timeline-500`). The scenario name targets a
  /// 500-entry timeline; this initial driver implementation seeds the
  /// existing dashboard preview fixture and lets the natural mount
  /// path exercise the G.1 signposts (`timeline.daemon.fetch`,
  /// `timeline.nodes.build`, `timeline.presentation.rebuild`).
  ///
  /// Full programmatic scroll wiring (a dedicated detail-pane scroll
  /// bus + ScrollViewReader proxy) is a follow-up — landing the
  /// scenario registration first lets the audit catalog reference
  /// `review-detail-timeline-500` and the manual Instruments
  /// recording flow already produces useful traces. Track-extension
  /// in the plan's "Verification across phases" section.
  static func runReviewDetailTimeline500Scenario(
    store: HarnessMonitorStore
  ) async -> ScenarioResult {
    await store.bootstrapIfNeeded()
    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: "perf.review-detail-timeline-500",
      event: "bootstrap.complete",
      details: [
        "connection_state": String(describing: store.connectionState)
      ]
    )
    // Settle long enough that the dashboard route + reviews
    // mount, the timeline fetch completes (G.1 signposts fire), and
    // the LazyVStack lays out its initial viewport. The audit captures
    // the natural-mount baseline today; a follow-up adds the dedicated
    // scroll bus + ScrollViewReader proxy for the conversation rows
    // region so the driver can post programmatic scroll events.
    await settle(.milliseconds(15_000))
    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: "perf.review-detail-timeline-500",
      event: "settle.complete"
    )
    return .completed
  }
}
