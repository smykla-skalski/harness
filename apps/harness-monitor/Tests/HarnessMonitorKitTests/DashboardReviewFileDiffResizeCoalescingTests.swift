import AppKit
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

/// A sidebar collapse/expand animates the detail pane's width every frame, and
/// the scroll view re-runs `layout()` on each one. Re-wrapping the whole diff on
/// every frame is what stutters the animation. These pin the contract that a
/// transient width sweep re-wraps the document once (when the width settles),
/// not once per frame.
@Suite("Dashboard review file diff resize coalescing")
struct DashboardReviewFileDiffResizeCoalescingTests {
  @Test("a width sweep coalesces to a single document re-wrap")
  @MainActor
  func widthSweepReWrapsOncePerSettle() {
    let document = DashboardReviewFileDiffDocument(
      patch: wrapHeavyPatch(changedLines: 600),
      language: .swift
    )
    let view = makeConfiguredGrid(document: document)

    // Initial settled layout (sidebar open): one full wrap of every row.
    view.resizeForViewportWidth(1_000)
    let baseline = view.wrapLayoutComputeCount
    #expect(baseline == document.rows.count)

    // Collapse the sidebar: the detail pane widens 1000 -> 1240 over 18 frames,
    // each delivered through the scroll view's per-frame resize entry.
    for frame in 1...18 {
      let width = 1_000 + CGFloat(frame) * (240.0 / 18.0)
      view.relayoutForViewportResize(width)
    }
    #expect(view.wrapLayoutComputeCount == baseline)

    // Once the width settles, exactly one more full re-wrap corrects the layout.
    view.flushPendingWrapLayout()
    #expect(view.wrapLayoutComputeCount == baseline + document.rows.count)
  }

  @MainActor
  private func makeConfiguredGrid(
    document: DashboardReviewFileDiffDocument
  ) -> DashboardReviewFileDiffGridContentView {
    let view = DashboardReviewFileDiffGridContentView()
    view.configure(
      .init(
        document: document,
        viewMode: .unified,
        fontScale: 1,
        softWrapEnabled: true
      )
    )
    return view
  }

  private func wrapHeavyPatch(changedLines: Int) -> ReviewFilePatch {
    var lines: [String] = [
      "diff --git a/Sources/WrapHeavy.swift b/Sources/WrapHeavy.swift",
      "index 3333333..4444444 100644",
      "--- a/Sources/WrapHeavy.swift",
      "+++ b/Sources/WrapHeavy.swift",
      "@@ -1,\(changedLines) +1,\(changedLines) @@",
    ]
    for index in 0..<changedLines {
      let line =
        " let wrappedValue\(index) = runTask("
        + "alpha: input.alpha\(index), "
        + "beta: transform(beta: input.beta\(index), gamma: input.gamma\(index)), "
        + "delta: computeDelta(lhs: previousDelta\(index),"
        + " rhs: nextDelta\(index), fallback: defaultDelta\(index)))"
      lines.append(line)
    }
    return ReviewFilePatch(
      path: "Sources/WrapHeavy.swift",
      patch: lines.joined(separator: "\n"),
      status: .modified,
      additions: UInt32(changedLines),
      deletions: 0,
      fetchedAt: "2026-05-25T12:00:00Z",
      headRefOid: "head-resize-coalesce"
    )
  }
}
