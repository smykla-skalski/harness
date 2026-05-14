import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Session timeline load-older marker")
struct SessionTimelineLoadOlderMarkerTests {
  @Test("Marker fires onAppear when hasOlder is true")
  func markerFiresOnAppearWhenHasOlder() {
    var fireCount = 0
    let marker = SessionTimelineLoadOlderMarker(
      hasOlder: true,
      onLoadOlder: { fireCount += 1 }
    )

    SessionTimelineLoadOlderMarkerTestProbe.invokeAppearAction(marker)

    #expect(fireCount == 1)
  }

  @Test("Marker stays inert when hasOlder is false")
  func markerStaysInertWhenNoOlder() {
    var fireCount = 0
    let marker = SessionTimelineLoadOlderMarker(
      hasOlder: false,
      onLoadOlder: { fireCount += 1 }
    )

    SessionTimelineLoadOlderMarkerTestProbe.invokeAppearAction(marker)

    #expect(fireCount == 0)
  }

  @Test("Marker identity changes when window grows so .id remounts the view")
  func markerIdentityChangesAcrossWindowGrowth() {
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

    let initialID = SessionTimelineLoadOlderMarker.identity(for: initialNavigation)
    let grownID = SessionTimelineLoadOlderMarker.identity(for: grownNavigation)

    #expect(initialID != grownID)
  }

  @Test("Marker identity is stable across rebuilds with same window")
  func markerIdentityStableForSameWindow() {
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
      SessionTimelineLoadOlderMarker.identity(for: first)
        == SessionTimelineLoadOlderMarker.identity(for: second)
    )
  }

  @Test("LazyVStack body has no conditional load-older child")
  func lazyVStackKeepsForEachOnlyContent() throws {
    let sourceFile = try timelineSource(named: "SessionTimelineList.swift")

    #expect(sourceFile.contains("LazyVStack(alignment: .leading, spacing: 0) {"))
    #expect(sourceFile.contains("ForEach(presentation.rows)"))
    #expect(!sourceFile.contains("if presentation.navigation.hasOlder {"))
  }

  @Test("Marker is wired to the older-chunk appender after the ForEach")
  func markerWiredToStoreAppender() throws {
    let listSource = try timelineSource(named: "SessionTimelineList.swift")
    let sectionSource = try timelineSource(named: "MonitorTimelineSection.swift")

    #expect(listSource.contains("SessionTimelineLoadOlderMarker("))
    #expect(listSource.contains("hasOlder: presentation.navigation.hasOlder"))
    #expect(listSource.contains("onLoadOlder: onRequestLoadOlder"))
    #expect(listSource.contains("SessionTimelineLoadOlderMarker.identity(for:"))
    #expect(sectionSource.contains("static let loadOlderChunkSize = 200"))
    #expect(sectionSource.contains("await store.appendSelectedTimelineOlderChunk("))
    #expect(sectionSource.contains("retainedLimit: nil"))
  }

  @Test("Marker placement keeps ForEach as the only LazyVStack iterator")
  func markerPlacementIsUnconditional() throws {
    let sourceFile = try timelineSource(named: "SessionTimelineList.swift")
    let lazyVStackOpen = sourceFile.range(of: "LazyVStack(alignment: .leading, spacing: 0) {")
    #expect(lazyVStackOpen != nil)

    let markerStart = sourceFile.range(of: "SessionTimelineLoadOlderMarker(")
    #expect(markerStart != nil)
    let forEachStart = sourceFile.range(of: "ForEach(presentation.rows)")
    #expect(forEachStart != nil)
    if let markerStart, let forEachStart {
      #expect(forEachStart.lowerBound < markerStart.lowerBound)
    }
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
        sessionId: "sess-marker",
        agentId: "agent-marker",
        taskId: nil,
        summary: "Marker entry \(index)",
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

@MainActor
enum SessionTimelineLoadOlderMarkerTestProbe {
  static func invokeAppearAction(_ marker: SessionTimelineLoadOlderMarker) {
    if marker.hasOlder {
      marker.onLoadOlder?()
    }
  }
}
