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

  @Test("Task key changes when window grows")
  func taskKeyChangesAcrossWindowGrowth() {
    let initialNavigation = SessionTimelineWindowNavigation(
      timeline: timelineEntries(count: 10),
      timelineWindow: timelineWindow(totalCount: 59, windowEnd: 10, hasOlder: true),
      isLoading: false
    )
    let grownNavigation = SessionTimelineWindowNavigation(
      timeline: timelineEntries(count: 59),
      timelineWindow: timelineWindow(totalCount: 59, windowEnd: 59, hasOlder: false),
      isLoading: false
    )

    let initialKey = SessionTimelineLoadOlderTaskKey(navigation: initialNavigation)
    let grownKey = SessionTimelineLoadOlderTaskKey(navigation: grownNavigation)

    #expect(initialKey != grownKey)
    #expect(initialKey.hasOlder == true)
    #expect(grownKey.hasOlder == false)
  }

  @Test("Task key is stable across rebuilds with same window")
  func taskKeyStableForSameWindow() {
    let timeline = timelineEntries(count: 10)
    let window = timelineWindow(totalCount: 59, windowEnd: 10, hasOlder: true)
    let first = SessionTimelineWindowNavigation(
      timeline: timeline,
      timelineWindow: window,
      isLoading: false
    )
    let second = SessionTimelineWindowNavigation(
      timeline: timeline,
      timelineWindow: window,
      isLoading: false
    )

    #expect(
      SessionTimelineLoadOlderTaskKey(navigation: first)
        == SessionTimelineLoadOlderTaskKey(navigation: second)
    )
  }

  @Test("Trigger wiring is present in SessionTimelineList: both task and onScrollGeometryChange")
  func triggerWiringPresent() throws {
    let listSource = try timelineSource(named: "SessionTimelineList.swift")

    #expect(listSource.contains(".onScrollGeometryChange("))
    #expect(listSource.contains("SessionTimelineNearBottomState.self"))
    #expect(listSource.contains("SessionTimelineNearBottomState.init(geometry:)"))
    #expect(listSource.contains(".task(id: SessionTimelineLoadOlderTaskKey"))
    #expect(listSource.contains("presentation.navigation.hasOlder"))
    #expect(listSource.contains("onRequestLoadOlder?()"))
  }

  @Test("LazyVStack body has no conditional load-older child")
  func lazyVStackKeepsForEachOnlyContent() throws {
    let sourceFile = try timelineSource(named: "SessionTimelineList.swift")

    #expect(sourceFile.contains("LazyVStack(alignment: .leading, spacing: 0) {"))
    #expect(sourceFile.contains("ForEach(presentation.rows)"))
    #expect(!sourceFile.contains("if presentation.navigation.hasOlder {"))
  }

  @Test("Section wires older-chunk appender")
  func sectionWiresStoreAppender() throws {
    let sectionSource = try timelineSource(named: "MonitorTimelineSection.swift")

    #expect(sectionSource.contains("static let loadOlderChunkSize = 200"))
    #expect(sectionSource.contains("await store.appendSelectedTimelineOlderChunk("))
    #expect(sectionSource.contains("retainedLimit: nil"))
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
