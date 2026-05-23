import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard review file diff documents")
struct DashboardReviewFileDiffDocumentTests {
  @Test("Unified patch rows preserve old and new line anchors")
  func unifiedPatchRowsPreserveLineAnchors() {
    let document = DashboardReviewFileDiffDocument(
      patch: patch(
        """
        @@ -10,3 +10,4 @@
         let kept = true
        -let oldValue = 1
        +let newValue = 2
        +let added = true
         return kept
        """
      ),
      language: .swift
    )

    #expect(document.rows.count == 6)
    #expect(document.rows[0].kind == .hunk)
    #expect(document.rows[1].oldLine == 10)
    #expect(document.rows[1].newLine == 10)
    #expect(document.rows[2].kind == .deletion)
    #expect(document.rows[2].oldLine == 11)
    #expect(document.rows[2].newLine == nil)
    #expect(document.rows[3].kind == .addition)
    #expect(document.rows[3].oldLine == nil)
    #expect(document.rows[3].newLine == 11)
    #expect(document.rows[4].newLine == 12)
    #expect(document.rows[5].oldLine == 12)
    #expect(document.rows[5].newLine == 13)
  }

  @Test("Source rows drop diff prefixes before highlighting")
  func sourceRowsDropDiffPrefixesBeforeHighlighting() {
    let document = DashboardReviewFileDiffDocument(
      patch: patch(
        """
        @@ -1 +1 @@
        -func oldName() {}
        +func newName() {}
        """
      ),
      language: .swift
    )

    #expect(document.rows[1].text == "func oldName() {}")
    #expect(document.rows[2].text == "func newName() {}")
    #expect(document.rows[1].unifiedPrefix == "-")
    #expect(document.rows[2].unifiedPrefix == "+")
  }

  @Test("Preview default keeps files just over two hundred lines in first window")
  func previewDefaultKeepsFilesJustOverTwoHundredLinesInFirstWindow() {
    #expect(ReviewFilePreview.defaultLineLimit >= 1_000)
  }

  private func patch(_ body: String) -> ReviewFilePatch {
    ReviewFilePatch(
      path: "Sources/File.swift",
      patch: body,
      status: .modified,
      additions: 2,
      deletions: 1,
      fetchedAt: "2026-05-23T12:00:00Z",
      headRefOid: "head"
    )
  }
}
