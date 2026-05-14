import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Session timeline load-older trigger")
struct SessionTimelineLoadOlderTriggerTests {
  @Test("Trigger reports near-bottom once content is within the threshold")
  func triggerReportsNearBottomWhenWithinThreshold() {
    let viewportHeight: CGFloat = 800
    let contentHeight: CGFloat = 4_000
    let nearBottomOffset =
      contentHeight - viewportHeight - SessionTimelineLoadOlderTrigger.nearBottomThreshold + 10

    let trigger = SessionTimelineLoadOlderTrigger(
      contentHeight: contentHeight,
      contentOffsetY: nearBottomOffset,
      viewportHeight: viewportHeight
    )

    #expect(trigger.isNearBottom == true)
  }

  @Test("Trigger stays inert above the near-bottom threshold")
  func triggerStaysInertAboveThreshold() {
    let trigger = SessionTimelineLoadOlderTrigger(
      contentHeight: 4_000,
      contentOffsetY: 0,
      viewportHeight: 800
    )

    #expect(trigger.isNearBottom == false)
  }

  @Test("Trigger fires at the absolute bottom")
  func triggerFiresAtAbsoluteBottom() {
    let viewportHeight: CGFloat = 800
    let contentHeight: CGFloat = 4_000

    let trigger = SessionTimelineLoadOlderTrigger(
      contentHeight: contentHeight,
      contentOffsetY: contentHeight - viewportHeight,
      viewportHeight: viewportHeight
    )

    #expect(trigger.isNearBottom == true)
  }

  @Test("Trigger handles short content where bottom is always visible")
  func triggerHandlesShortContent() {
    let trigger = SessionTimelineLoadOlderTrigger(
      contentHeight: 200,
      contentOffsetY: 0,
      viewportHeight: 800
    )

    #expect(trigger.isNearBottom == true)
  }

  @Test("LazyVStack body has no conditional load-older child")
  func lazyVStackKeepsForEachOnlyContent() throws {
    let sourceFile = try timelineSource(named: "MonitorTimelineSection.swift")

    #expect(sourceFile.contains("LazyVStack(alignment: .leading, spacing: 0) {"))
    #expect(sourceFile.contains("ForEach(presentation.rows)"))
    #expect(!sourceFile.contains("if presentation.navigation.hasOlder {"))
  }

  @Test("Scroll-geometry trigger is wired to the older-chunk appender")
  func scrollGeometryWiredToStoreAppender() throws {
    let sourceFile = try timelineSource(named: "MonitorTimelineSection.swift")

    #expect(sourceFile.contains(".onScrollGeometryChange("))
    #expect(sourceFile.contains("SessionTimelineLoadOlderTrigger.self"))
    #expect(sourceFile.contains("SessionTimelineLoadOlderTrigger.init(geometry:)"))
    #expect(sourceFile.contains("static let loadOlderChunkSize = 200"))
    #expect(sourceFile.contains("await store.appendSelectedTimelineOlderChunk("))
    #expect(sourceFile.contains("retainedLimit: nil"))
  }

  @Test("Trigger uses task-id state to fire on (isNearBottom, hasOlder)")
  func triggerFiresViaTaskComposite() throws {
    let sourceFile = try timelineSource(named: "MonitorTimelineSection.swift")

    #expect(sourceFile.contains("@State private var isNearBottom"))
    #expect(sourceFile.contains("if newValue.isNearBottom != isNearBottom"))
    #expect(sourceFile.contains("isNearBottom = newValue.isNearBottom"))
    #expect(sourceFile.contains(".task("))
    #expect(sourceFile.contains("id: SessionTimelineLoadOlderState("))
    #expect(sourceFile.contains("isNearBottom: isNearBottom"))
    #expect(sourceFile.contains("hasOlder: presentation.navigation.hasOlder"))
    #expect(sourceFile.contains("windowEnd: presentation.navigation.windowEnd"))
    #expect(sourceFile.contains("guard isNearBottom, presentation.navigation.hasOlder else"))
  }

  @Test("Composite state struct is Equatable on (isNearBottom, hasOlder, windowEnd)")
  func compositeStateEquatable() {
    let baseline = SessionTimelineLoadOlderState(
      isNearBottom: true,
      hasOlder: true,
      windowEnd: 100
    )
    #expect(
      baseline
        == SessionTimelineLoadOlderState(isNearBottom: true, hasOlder: true, windowEnd: 100))
    #expect(
      baseline
        != SessionTimelineLoadOlderState(isNearBottom: false, hasOlder: true, windowEnd: 100))
    #expect(
      baseline
        != SessionTimelineLoadOlderState(isNearBottom: true, hasOlder: false, windowEnd: 100))
    #expect(
      baseline
        != SessionTimelineLoadOlderState(isNearBottom: true, hasOlder: true, windowEnd: 101))
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
}
