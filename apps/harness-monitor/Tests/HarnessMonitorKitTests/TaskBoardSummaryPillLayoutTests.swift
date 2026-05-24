import AppKit
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task board summary pill layout")
struct TaskBoardSummaryPillLayoutTests {
  @Test("Summary pills keep a stable height across icon variants")
  func summaryPillsKeepAStableHeightAcrossIconVariants() {
    let baselineHeight = fittingHeight(
      for: TaskBoardSummaryPill(
        value: "27",
        label: "Needs You"
      )
    )
    let needsYouHeight = fittingHeight(
      for: TaskBoardSummaryPill(
        value: "27",
        label: "Needs You",
        systemImage: "person.crop.circle.badge.exclamationmark"
      )
    )
    let openHeight = fittingHeight(
      for: TaskBoardSummaryPill(
        value: "27",
        label: "Open",
        systemImage: "rectangle.stack"
      )
    )
    let reviewHeight = fittingHeight(
      for: TaskBoardSummaryPill(
        value: "27",
        label: "Review",
        systemImage: "checkmark.seal"
      )
    )

    #expect(abs(baselineHeight - needsYouHeight) <= 0.5)
    #expect(abs(needsYouHeight - openHeight) <= 0.5)
    #expect(abs(needsYouHeight - reviewHeight) <= 0.5)
  }

  private func fittingHeight<Content: View>(
    for view: Content
  ) -> CGFloat {
    let host = NSHostingView(
      rootView: view.harnessPreviewSceneAppearance()
    )
    host.frame = CGRect(x: 0, y: 0, width: 240, height: 64)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
  }
}
