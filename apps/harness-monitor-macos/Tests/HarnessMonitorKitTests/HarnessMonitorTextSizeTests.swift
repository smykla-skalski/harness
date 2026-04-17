import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("HarnessMonitorTextSize magnification index delta")
struct HarnessMonitorTextSizeTests {
  @Test("Pinch out above threshold increments index")
  func pinchOutAboveThreshold() {
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 1.2, currentIndex: 3) == 1)
  }

  @Test("Pinch in above threshold decrements index")
  func pinchInAboveThreshold() {
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 0.8, currentIndex: 3) == -1)
  }

  @Test("Magnification within threshold returns zero")
  func withinThresholdReturnsZero() {
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 1.1, currentIndex: 3) == 0)
  }

  @Test("At or just inside threshold boundary returns zero")
  func atThresholdBoundaryReturnsZero() {
    // 1.15 is exactly at the positive boundary (change == 0.15, not > 0.15)
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 1.15, currentIndex: 3) == 0)
    // Use 0.86 to stay clearly inside the negative threshold (change = -0.14)
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 0.86, currentIndex: 3) == 0)
  }

  @Test("Just above threshold returns positive one")
  func justAboveThresholdReturnsPositive() {
    #expect(
      HarnessMonitorTextSize.indexDelta(forMagnification: 1.15 + 0.01, currentIndex: 3) == 1)
  }

  @Test("Just below negative threshold returns negative one")
  func justBelowNegativeThresholdReturnsNegative() {
    #expect(
      HarnessMonitorTextSize.indexDelta(forMagnification: 0.85 - 0.01, currentIndex: 3) == -1)
  }

  @Test("At max index returns zero even with large magnification")
  func atMaxIndexReturnsZero() {
    let maxIndex = HarnessMonitorTextSize.scales.count - 1
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 2.0, currentIndex: maxIndex) == 0)
  }

  @Test("At min index returns zero even with small magnification")
  func atMinIndexReturnsZero() {
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 0.5, currentIndex: 0) == 0)
  }

  @Test("Custom threshold parameter")
  func customThreshold() {
    #expect(
      HarnessMonitorTextSize.indexDelta(
        forMagnification: 1.05, currentIndex: 3, threshold: 0.04) == 1)
    #expect(
      HarnessMonitorTextSize.indexDelta(
        forMagnification: 1.05, currentIndex: 3, threshold: 0.1) == 0)
  }

  @Test("Pinch out increments across all non-max indices", arguments: 0..<6)
  func pinchOutIncrementsAtValidIndices(index: Int) {
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 1.3, currentIndex: index) == 1)
  }

  @Test("Pinch in decrements across all non-min indices", arguments: 1...6)
  func pinchInDecrementsAtValidIndices(index: Int) {
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 0.6, currentIndex: index) == -1)
  }

  @Test("No change when magnification is exactly 1.0")
  func noChangeAtExactlyOne() {
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 1.0, currentIndex: 3) == 0)
  }
}

@MainActor
@Suite("Session cockpit empty state row")
struct SessionCockpitEmptyStateRowTests {
  @Test("Tasks placeholder uses the shared message and secondary styling contract")
  func tasksPlaceholderUsesSharedMessageAndSecondaryStylingContract() {
    #expect(SessionCockpitEmptyStateRow.Section.tasks.message == "No tasks right now")
    #expect(SessionCockpitEmptyStateRow.usesSecondaryForeground)
  }

  @Test("Tasks placeholder scales across the smallest and largest text sizes")
  func tasksPlaceholderScalesAcrossSmallestAndLargestTextSizes() {
    let minimumScale = HarnessMonitorTextSize.scale(at: 0)
    let maximumScale = HarnessMonitorTextSize.scale(at: HarnessMonitorTextSize.scales.count - 1)
    let minimumSize = fittingSize(for: .tasks, scale: minimumScale)
    let maximumSize = fittingSize(for: .tasks, scale: maximumScale)

    #expect(minimumSize.height > 0)
    #expect(maximumSize.height >= minimumSize.height)
    #expect(maximumSize.width > minimumSize.width)
  }

  private func fittingSize(
    for section: SessionCockpitEmptyStateRow.Section,
    scale: CGFloat
  ) -> CGSize {
    let host = hostingView(for: section, scale: scale)
    return host.fittingSize
  }

  private func hostingView(
    for section: SessionCockpitEmptyStateRow.Section,
    scale: CGFloat
  ) -> NSHostingView<some View> {
    let host = NSHostingView(
      rootView: SessionCockpitEmptyStateRow(section: section)
        .environment(\.fontScale, scale)
    )
    host.frame = CGRect(x: 0, y: 0, width: 480, height: 120)
    host.layoutSubtreeIfNeeded()
    return host
  }
}

@MainActor
@Suite("Agent task drop feedback layout")
struct AgentTaskDropFeedbackLayoutTests {
  @Test("Drop feedback stays within the worker-card height at the largest text size")
  func dropFeedbackStaysWithinWorkerCardHeightAtLargestTextSize() {
    let feedback = AgentTaskDropFeedback(
      agent: PreviewFixtures.agents[1],
      queuedTaskCount: 3,
      isSessionReadOnly: false
    )
    let maximumScale = HarnessMonitorTextSize.scale(at: HarnessMonitorTextSize.scales.count - 1)
    let fittingSize = fittingSize(
      for: feedback,
      width: 220,
      scale: maximumScale
    )

    #expect(fittingSize.height <= SessionCockpitLayout.laneCardHeight)
  }

  private func fittingSize(
    for feedback: AgentTaskDropFeedback,
    width: CGFloat,
    scale: CGFloat
  ) -> CGSize {
    let host = NSHostingView(
      rootView: AgentTaskDropFeedbackOverlay(feedback: feedback)
        .environment(\.fontScale, scale)
    )
    host.frame = CGRect(
      x: 0,
      y: 0,
      width: width,
      height: SessionCockpitLayout.laneCardHeight
    )
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }
}

@MainActor
@Suite("Task drag preview layout")
struct TaskDragPreviewLayoutTests {
  @Test("Drag preview keeps a compact render-safe footprint")
  func dragPreviewKeepsACompactRenderSafeFootprint() {
    let task = PreviewFixtures.taskDropTask
    let previewSize = fittingSize(
      for: TaskDragPreviewCard(task: task),
      width: 480
    )

    #expect(previewSize.width <= 320)
    #expect(previewSize.height < SessionCockpitLayout.laneCardHeight)
  }

  private func fittingSize<Content: View>(
    for view: Content,
    width: CGFloat
  ) -> CGSize {
    let host = NSHostingView(rootView: view)
    host.frame = CGRect(x: 0, y: 0, width: width, height: 240)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }
}

@Suite("Task drag feedback metrics")
struct TaskDragFeedbackMetricsTests {
  @Test("Hand-feedback metrics scale dynamically across compact task card sizes")
  func handFeedbackMetricsScaleDynamicallyAcrossCompactTaskCardSizes() {
    let compactCardSizes = [
      CGSize(width: 220, height: 54),
      CGSize(width: 236, height: 56),
      CGSize(width: 280, height: 60),
      CGSize(width: 320, height: 62),
      CGSize(width: 420, height: 72),
    ]

    var previousMetrics: TaskDragFeedbackMetrics?

    for compactCardSize in compactCardSizes {
      let metrics = TaskDragFeedbackMetrics(cardSize: compactCardSize)

      #expect(metrics.iconSize < metrics.haloDiameter)
      #expect(metrics.blurRadius > (metrics.iconSize * 0.5))
      #expect(metrics.totalFootprint <= compactCardSize.height * 1.2)

      if let previousMetrics {
        #expect(metrics.haloDiameter > previousMetrics.haloDiameter)
        #expect(metrics.blurRadius > previousMetrics.blurRadius)
        #expect(metrics.iconSize > previousMetrics.iconSize)
      }

      previousMetrics = metrics
    }
  }
}

@MainActor
@Suite("Session task card layout")
struct SessionTaskCardLayoutTests {
  @Test("Task card height follows the compact summary content without extra reserve space")
  func taskCardHeightFollowsCompactSummaryContent() {
    let width: CGFloat = 320
    let task = PreviewFixtures.taskDropTask
    let cardSize = fittingSize(
      for: SessionTaskSummaryCard(
        store: HarnessMonitorPreviewStoreFactory.makeStore(for: .taskDropCockpit),
        sessionID: PreviewFixtures.summary.sessionId,
        task: task,
        inspectTask: { _ in }
      ),
      width: width
    )
    let contentSize = fittingSize(
      for: SessionTaskCompactSummaryContent(task: task)
        .padding(HarnessMonitorTheme.cardPadding),
      width: width
    )

    #expect(cardSize.height == contentSize.height)
  }

  private func fittingSize<Content: View>(
    for view: Content,
    width: CGFloat
  ) -> CGSize {
    let host = NSHostingView(rootView: view)
    host.frame = CGRect(x: 0, y: 0, width: width, height: 240)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }
}
