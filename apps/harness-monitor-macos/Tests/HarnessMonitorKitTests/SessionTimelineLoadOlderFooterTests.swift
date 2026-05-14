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
    let sourceFile = try timelineSource(named: "SessionTimelineList.swift")

    #expect(sourceFile.contains("LazyVStack(alignment: .leading, spacing: 0) {"))
    #expect(sourceFile.contains("ForEach(presentation.rows)"))
    #expect(!sourceFile.contains("if presentation.navigation.hasOlder {"))
  }

  @Test("Scroll-geometry trigger is wired to the older-chunk appender")
  func scrollGeometryWiredToStoreAppender() throws {
    let listSource = try timelineSource(named: "SessionTimelineList.swift")
    let sectionSource = try timelineSource(named: "MonitorTimelineSection.swift")

    #expect(listSource.contains(".onScrollGeometryChange("))
    #expect(listSource.contains("SessionTimelineLoadOlderTrigger.self"))
    #expect(listSource.contains("SessionTimelineLoadOlderTrigger.init(geometry:)"))
    #expect(sectionSource.contains("static let loadOlderChunkSize = 200"))
    #expect(sectionSource.contains("await store.appendSelectedTimelineOlderChunk("))
    #expect(sectionSource.contains("retainedLimit: nil"))
  }

  @Test("Trigger fires on first content render OR rising near-bottom edge")
  func triggerFiresOnFirstRenderOrRisingEdge() throws {
    let sourceFile = try timelineSource(named: "SessionTimelineList.swift")

    #expect(
      sourceFile.contains("let firstRender = !oldValue.contentRendered && newValue.contentRendered")
    )
    #expect(
      sourceFile.contains("let risingNearBottom = !oldValue.isNearBottom && newValue.isNearBottom"))
    #expect(sourceFile.contains("guard firstRender || risingNearBottom else"))
    #expect(
      sourceFile.contains("guard newValue.isNearBottom, presentation.navigation.hasOlder else"))
  }

  @Test("Trigger reports content not rendered when contentHeight is zero")
  func triggerContentRenderedReflectsContentHeight() {
    let pristine = SessionTimelineLoadOlderTrigger(
      contentHeight: 0,
      contentOffsetY: 0,
      viewportHeight: 800
    )
    #expect(pristine.contentRendered == false)

    let measured = SessionTimelineLoadOlderTrigger(
      contentHeight: 600,
      contentOffsetY: 0,
      viewportHeight: 800
    )
    #expect(measured.contentRendered == true)
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
