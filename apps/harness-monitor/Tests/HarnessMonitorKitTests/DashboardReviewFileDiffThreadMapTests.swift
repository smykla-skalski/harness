import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard review file diff thread map")
struct DashboardReviewFileDiffThreadMapTests {
  @Test("thread map preserves row matching semantics without duplicate anchors")
  func threadMapPreservesRowMatchingSemanticsWithoutDuplicateAnchors() {
    let rows = [
      row(id: 1, oldLine: 1, newLine: 1, diffPosition: 10),
      row(id: 2, oldLine: 2, newLine: nil, diffPosition: 11),
      row(id: 3, oldLine: nil, newLine: 2, diffPosition: 12),
    ]
    let threads = [
      anchor(id: "any-line", side: nil, line: 1, diffPosition: nil),
      anchor(id: "old-line", side: .old, line: 2, diffPosition: nil),
      anchor(id: "new-line", side: .new, line: 2, diffPosition: nil),
      anchor(id: "position", side: .new, line: 1, diffPosition: 10),
    ]

    let map = DashboardReviewFileDiffThreadMap.build(rows: rows, threads: threads)

    #expect(map[1]?.map(\.id) == ["any-line", "position"])
    #expect(map[2]?.map(\.id) == ["old-line"])
    #expect(map[3]?.map(\.id) == ["new-line"])
  }

  private func row(
    id: Int,
    oldLine: Int?,
    newLine: Int?,
    diffPosition: Int?
  ) -> DashboardReviewFileDiffRow {
    DashboardReviewFileDiffRow(
      id: id,
      kind: .context,
      oldLine: oldLine,
      newLine: newLine,
      diffPosition: diffPosition,
      text: "line",
      contextGap: nil
    )
  }

  private func anchor(
    id: String,
    side: DashboardReviewFileDiffSide?,
    line: Int?,
    diffPosition: Int?
  ) -> DashboardReviewFileThreadAnchor {
    DashboardReviewFileThreadAnchor(
      id: id,
      path: "Sources/File.swift",
      side: side,
      line: line,
      diffPosition: diffPosition,
      commentCount: 1,
      isResolved: false,
      authorLogin: nil,
      preview: "",
      url: nil
    )
  }
}
