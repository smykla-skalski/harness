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

  @Test("Summary pill chrome preserves geometry across text sizes")
  func summaryPillChromePreservesGeometryAcrossTextSizes() {
    for textSizeIndex in HarnessMonitorTextSize.scales.indices {
      let contentHeight = fittingHeight(
        for: TaskBoardSummaryPill(
          value: "119",
          label: "Eval",
          chrome: .content
        ),
        textSizeIndex: textSizeIndex
      )
      let controlHeight = fittingHeight(
        for: TaskBoardSummaryPill(
          value: "119",
          label: "Eval",
          chrome: .control
        ),
        textSizeIndex: textSizeIndex
      )

      #expect(abs(contentHeight - controlHeight) <= 0.5)
    }
  }

  private func fittingHeight<Content: View>(
    for view: Content,
    textSizeIndex: Int = HarnessMonitorTextSize.defaultIndex
  ) -> CGFloat {
    let rootView =
      view
      .environment(\.harnessControlPillTransparencyEnabled, false)
      .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let host = NSHostingView(rootView: rootView)
    host.frame = CGRect(x: 0, y: 0, width: 240, height: 64)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
  }
}
