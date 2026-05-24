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

    #expect(document.rows.count == 7)
    #expect(document.rows[0].kind == .contextGap)
    #expect(document.rows[0].contextGap?.oldHiddenCount == 9)
    #expect(document.rows[1].kind == .hunk)
    #expect(document.rows[2].oldLine == 10)
    #expect(document.rows[2].newLine == 10)
    #expect(document.rows[3].kind == .deletion)
    #expect(document.rows[3].oldLine == 11)
    #expect(document.rows[3].newLine == nil)
    #expect(document.rows[4].kind == .addition)
    #expect(document.rows[4].oldLine == nil)
    #expect(document.rows[4].newLine == 11)
    #expect(document.rows[5].newLine == 12)
    #expect(document.rows[6].oldLine == 12)
    #expect(document.rows[6].newLine == 13)
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
    #expect(document.longestCodeCharacterCount == "func newName() {}".count)
  }

  @Test("Diff headers and rename metadata do not consume source line numbers")
  func diffHeadersDoNotConsumeSourceLineNumbers() {
    let document = DashboardReviewFileDiffDocument(
      patch: patch(
        """
        diff --git a/Old.swift b/New.swift
        similarity index 88%
        rename from Old.swift
        rename to New.swift
        index 1111111..2222222 100644
        --- a/Old.swift
        +++ b/New.swift
        @@ -20,2 +20,2 @@
         let kept = true
        -let old = true
        +let new = true
        """
      ),
      language: .swift
    )

    #expect(document.rows[0].kind == .metadata)
    #expect(document.rows[6].kind == .metadata)
    #expect(document.rows[7].kind == .contextGap)
    #expect(document.rows[8].kind == .hunk)
    #expect(document.rows[9].oldLine == 20)
    #expect(document.rows[9].newLine == 20)
    #expect(document.rows[10].oldLine == 21)
    #expect(document.rows[11].newLine == 21)
  }

  @Test("Deleted file hunks keep old-side anchors")
  func deletedFileHunksKeepOldSideAnchors() {
    let document = DashboardReviewFileDiffDocument(
      patch: patch(
        """
        diff --git a/Removed.swift b/Removed.swift
        deleted file mode 100644
        --- a/Removed.swift
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -let removed = true
        -return removed
        """
      ),
      language: .swift
    )

    let deletedRows = document.rows.filter { $0.kind == .deletion }
    #expect(deletedRows.map(\.oldLine) == [1, 2])
    #expect(deletedRows.allSatisfy { $0.newLine == nil })
  }

  @Test("Binary and mode-only patches stay metadata only")
  func binaryAndModeOnlyPatchesStayMetadataOnly() {
    let document = DashboardReviewFileDiffDocument(
      patch: patch(
        """
        diff --git a/logo.png b/logo.png
        index 1111111..2222222 100644
        Binary files a/logo.png and b/logo.png differ
        """
      ),
      language: .generic
    )

    #expect(document.rows.map(\.kind).allSatisfy { $0 == .metadata })
    #expect(document.rows.allSatisfy { $0.oldLine == nil && $0.newLine == nil })
  }

  @Test("Thread index matches review threads to source rows")
  func threadIndexMatchesReviewThreadsToSourceRows() {
    let document = DashboardReviewFileDiffDocument(
      patch: patch(
        """
        @@ -1,2 +1,2 @@
         let kept = true
        -let old = true
        +let new = true
        """
      ),
      language: .swift
    )
    let index = DashboardReviewFileThreadIndex(
      entries: [
        .reviewThread(
          ReviewThreadPayload(
            id: "thread-1",
            createdAt: "2026-05-23T12:00:00Z",
            isResolved: false,
            path: "Sources/File.swift",
            line: 2,
            diffSide: "RIGHT",
            comments: [
              ReviewThreadCommentPayload(
                id: "comment-1",
                body: "Please rename this value.",
                createdAt: "2026-05-23T12:00:00Z"
              )
            ]
          )
        )
      ]
    )

    let anchors = index.anchors(forPath: "Sources/File.swift")
    #expect(anchors.count == 1)
    #expect(index.hasUnresolvedAnchors(forPath: "Sources/File.swift"))
    #expect(index.unresolvedAnchorCount(forPath: "Sources/File.swift") == 1)
    #expect(!index.hasUnresolvedAnchors(forPath: "Sources/Other.swift"))
    #expect(index.unresolvedAnchorCount(forPath: "Sources/Other.swift") == 0)
    #expect(document.rows.contains { $0.matches(anchor: anchors[0]) })
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
