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

  @Test("Unified grid width keeps growing for very long lines")
  @MainActor
  func unifiedGridWidthKeepsGrowingForVeryLongLines() {
    let contentView = DashboardReviewFileDiffGridContentView()
    contentView.viewMode = .unified
    contentView.characterWidth = 8
    contentView.longestCodeCharacterCount = 1_000

    #expect(contentView.contentWidth(viewportWidth: 1_200) == 8_130)
  }

  @Test("Split grid width keeps growing for very long lines")
  @MainActor
  func splitGridWidthKeepsGrowingForVeryLongLines() {
    let contentView = DashboardReviewFileDiffGridContentView()
    contentView.viewMode = .split
    contentView.characterWidth = 8
    contentView.longestCodeCharacterCount = 1_000

    #expect(contentView.contentWidth(viewportWidth: 1_200) == 16_210)
  }

  @Test("wrapped unified grid clamps content width to the viewport")
  @MainActor
  func wrappedUnifiedGridClampsWidthToViewport() {
    let contentView = DashboardReviewFileDiffGridContentView()
    contentView.viewMode = .unified
    contentView.softWrapEnabled = true
    contentView.characterWidth = 8
    contentView.longestCodeCharacterCount = 1_000

    #expect(contentView.contentWidth(viewportWidth: 1_200) == 1_200)
  }

  @Test("wrapped split grid clamps content width to the viewport")
  @MainActor
  func wrappedSplitGridClampsWidthToViewport() {
    let contentView = DashboardReviewFileDiffGridContentView()
    contentView.viewMode = .split
    contentView.softWrapEnabled = true
    contentView.characterWidth = 8
    contentView.longestCodeCharacterCount = 1_000

    #expect(contentView.contentWidth(viewportWidth: 1_200) == 1_200)
  }

  @Test("source rows expand tabs for display and keep originals for copy")
  func sourceRowsExpandTabsForDisplay() {
    let document = DashboardReviewFileDiffDocument(
      patch: patch("@@ -1,2 +1,2 @@\n \tkept := true\n-\told := 1\n+\tnew := 2"),
      language: .go
    )

    let codeRows = document.rows.filter {
      $0.kind == .addition || $0.kind == .deletion || $0.kind == .context
    }
    #expect(!codeRows.isEmpty)
    #expect(codeRows.allSatisfy { !$0.text.contains("\t") })
    #expect(codeRows.allSatisfy { $0.text.hasPrefix("        ") })
    #expect(codeRows.allSatisfy { $0.copyText.contains("\t") })
  }

  @Test("tab width is configurable for display expansion")
  func tabWidthConfigurableForDisplay() {
    let body = "@@ -1 +1 @@\n+\tx := 1"
    let wide = DashboardReviewFileDiffDocument(patch: patch(body), language: .go, tabWidth: 8)
    let narrow = DashboardReviewFileDiffDocument(patch: patch(body), language: .go, tabWidth: 4)

    let wideRow = wide.rows.first { $0.kind == .addition }
    let narrowRow = narrow.rows.first { $0.kind == .addition }
    #expect(wideRow?.text == "        x := 1")
    #expect(narrowRow?.text == "    x := 1")
    #expect(wideRow?.copyText == "\tx := 1")
  }

  @Test("tab-indented gofmt field expands then wraps within the budget")
  func gofmtTabIndentedFieldWrapsWithinBudget() {
    // The screenshot regression end to end: a tab-indented, tab-aligned Go
    // struct field. The document expands the tabs, then the wrap engine must
    // keep every visual line inside the column budget at tight widths and
    // actually wrap rather than draw past the column.
    let body = "@@ -1 +1 @@\n+\tXdsStreamRegistrationInProgressRetries\t*prometheus.CounterVec"
    let document = DashboardReviewFileDiffDocument(
      patch: patch(body),
      language: .go,
      tabWidth: 8
    )
    guard let codeRow = document.rows.first(where: { $0.kind == .addition }) else {
      Issue.record("expected an addition row in the expanded document")
      return
    }
    for limit in [16, 24, 40] {
      let layout = DashboardReviewFileDiffWrapLayout.layout(
        row: codeRow,
        language: .go,
        softWrapEnabled: true,
        characterLimit: limit
      )
      #expect(layout.lineCount > 1)
      #expect(layout.displayLines.allSatisfy { $0.count <= limit })
    }
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
