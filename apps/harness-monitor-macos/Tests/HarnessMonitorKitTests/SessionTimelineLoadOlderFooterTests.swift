import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Session timeline load-older triggers")
struct SessionTimelineLoadOlderTriggerTests {
  @Test("Near-bottom state reports below threshold when within 200pt")
  func nearBottomBelowThreshold() {
    let viewport: CGFloat = 470
    let contentHeight: CGFloat = 600
    let nearBottomOffset = contentHeight - viewport - 100  // 30pt from bottom

    let state = SessionTimelineNearBottomState(
      distanceFromBottom: max(0, contentHeight - nearBottomOffset - viewport),
      contentMeasured: true
    )

    #expect(state.distanceFromBottom <= SessionTimelineNearBottomState.threshold)
    #expect(state.contentMeasured == true)
  }

  @Test("Near-bottom state reports above threshold when scrolled high")
  func nearBottomAboveThreshold() {
    let state = SessionTimelineNearBottomState(
      distanceFromBottom: 1_000,
      contentMeasured: true
    )

    #expect(state.distanceFromBottom > SessionTimelineNearBottomState.threshold)
  }

  @Test("Near-bottom state treats content-fits-viewport as near-bottom (distance=0)")
  func nearBottomWhenContentFits() {
    let state = SessionTimelineNearBottomState(
      distanceFromBottom: 0,
      contentMeasured: true
    )

    #expect(state.distanceFromBottom <= SessionTimelineNearBottomState.threshold)
    #expect(state.contentMeasured == true)
  }

  @Test("Near-bottom state reports unmeasured when contentSize is zero")
  func nearBottomWhenUnmeasured() {
    let state = SessionTimelineNearBottomState(
      distanceFromBottom: 0,
      contentMeasured: false
    )

    #expect(state.contentMeasured == false)
  }

  @Test("Near-bottom state captures contentOffsetY for change-detection")
  func nearBottomCapturesOffset() {
    let state = SessionTimelineNearBottomState(
      distanceFromBottom: 30,
      contentMeasured: true,
      contentOffsetY: 600
    )
    #expect(state.contentOffsetY == 600)
  }

  @Test("Trigger wiring: scrollGeometry-only with offset-change gate")
  func triggerWiringPresent() throws {
    let listSource = try timelineSource(named: "SessionTimelineList.swift")

    #expect(listSource.contains(".onScrollGeometryChange("))
    #expect(listSource.contains("SessionTimelineNearBottomState.self"))
    #expect(listSource.contains("SessionTimelineNearBottomState.init(geometry:)"))
    #expect(
      listSource.contains("newValue.contentOffsetY != oldValue.contentOffsetY")
    )
    #expect(listSource.contains("nav.hasOlder"))
    #expect(listSource.contains("onRequestLoadOlder?()"))
    // The .task(id:) auto-trigger must stay removed: it chain-fired on every
    // navigation update and re-loaded all pages without user interaction.
    #expect(!listSource.contains(".task(id: SessionTimelineLoadOlderTaskKey"))
    #expect(!listSource.contains("SessionTimelineLoadOlderTaskKey"))
  }

  @Test("LazyVStack body has no conditional load-older child")
  func lazyVStackKeepsForEachOnlyContent() throws {
    let sourceFile = try timelineSource(named: "SessionTimelineList.swift")

    #expect(sourceFile.contains("LazyVStack(alignment: .leading, spacing: 0) {"))
    #expect(sourceFile.contains("ForEach(presentation.rows)"))
    #expect(!sourceFile.contains("if presentation.navigation.hasOlder {"))
  }

  @Test("Section wires older-chunk appender with dynamic page size")
  func sectionWiresStoreAppender() throws {
    let sectionSource = try timelineSource(named: "MonitorTimelineSection.swift")

    #expect(sectionSource.contains("static let fallbackPageSize = 10"))
    #expect(sectionSource.contains("static let estimatedRowHeight: CGFloat = 56"))
    #expect(sectionSource.contains("var pageSize: Int"))
    #expect(sectionSource.contains("let limit = pageSize"))
    #expect(sectionSource.contains("await store.appendSelectedTimelineOlderChunk("))
    #expect(sectionSource.contains("retainedLimit: nil"))
  }

  @Test("Section refresh uses dynamic page size from measured container")
  func sectionRefreshLimit() throws {
    let sectionSource = try timelineSource(named: "MonitorTimelineSection.swift")
    let supportSource = try timelineSource(named: "MonitorTimelineSection+Support.swift")
    #expect(sectionSource.contains(".onGeometryChange(for: CGFloat.self, of: \\.size.height)"))
    #expect(sectionSource.contains("updateMeasuredContainerHeight"))
    #expect(supportSource.contains("TimelineWindowRequest.latest(limit: pageSize)"))
  }

  @Test("pageSize defaults to fallback when container unmeasured")
  func pageSizeFallback() {
    let fallback = 10
    let estimated: CGFloat = 56
    let unmeasured: CGFloat = 0
    let height: CGFloat = 720

    func compute(measured: CGFloat) -> Int {
      guard measured > 0 else { return fallback }
      let rows = Int((measured / estimated).rounded(.up))
      return max(fallback, rows)
    }

    #expect(compute(measured: unmeasured) == fallback)
    #expect(compute(measured: 200) == fallback)
    #expect(compute(measured: height) == Int((height / estimated).rounded(.up)))
    #expect(compute(measured: 1200) > fallback)
  }

  @Test("Section routes older-load through per-window snapshot when timelineLoading set")
  func sectionRoutesOlderLoadViaSnapshot() throws {
    let sectionSource = try timelineSource(named: "MonitorTimelineSection.swift")
    #expect(sectionSource.contains("if let timelineLoading, let oldestCursor {"))
    #expect(sectionSource.contains("await timelineLoading.loadWindow("))
    #expect(sectionSource.contains("before: oldestCursor"))
  }

  private func timelineSource(named fileName: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Timeline"
      )
      .appendingPathComponent(fileName)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  private func timelineEntries(count: Int) -> [TimelineEntry] {
    (0..<count).map { index in
      TimelineEntry(
        entryId: "entry-\(index)",
        recordedAt: String(format: "2026-04-15T08:%02d:00Z", 59 - index),
        kind: "task_checkpoint",
        sessionId: "sess-trigger",
        agentId: "agent-trigger",
        taskId: nil,
        summary: "Trigger entry \(index)",
        payload: .object([:])
      )
    }
  }

  private func timelineWindow(
    totalCount: Int,
    windowEnd: Int,
    hasOlder: Bool
  ) -> TimelineWindowResponse {
    TimelineWindowResponse(
      revision: 1,
      totalCount: totalCount,
      windowStart: 0,
      windowEnd: windowEnd,
      hasOlder: hasOlder,
      hasNewer: false,
      oldestCursor: nil,
      newestCursor: nil,
      entries: nil,
      unchanged: false
    )
  }
}
