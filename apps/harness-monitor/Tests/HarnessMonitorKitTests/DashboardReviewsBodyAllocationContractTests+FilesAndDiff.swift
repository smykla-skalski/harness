import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension DashboardReviewsBodyAllocationContractTests {
  @Test("files detail menu avoids thread URL arrays in body")
  func filesDetailMenuAvoidsThreadURLArraysInBody() throws {
    let detailSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFilesModeDetailPane.swift"
    )

    #expect(detailSource.contains("let fileThreads = threadIndex.threads(forPath: file.path)"))
    #expect(detailSource.contains("private func copyThreadURLs("))
    #expect(!detailSource.contains("let urls = threadIndex.threads(forPath: file.path)"))
    #expect(!detailSource.contains(".compactMap(\\.url)"))
    #expect(!detailSource.contains("].joined(separator: \":\")"))
  }

  @Test("files detail reuses cached diff documents")
  func filesDetailReusesCachedDiffDocuments() throws {
    let detailSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFilesModeDetailPane.swift"
    )
    let contentSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFileDiffContent.swift"
    )
    let cacheSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFileDiffDocumentCache.swift"
    )
    let splitSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFileDiffSplit.swift"
    )
    let unifiedSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFileDiffUnified.swift"
    )
    let previewSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFileDiffPreview.swift"
    )

    // The pane owns the parsed-document cache and hands it to the diff content
    // view, which builds every document through it at the configured tab width.
    #expect(
      detailSource.contains(
        "@State private var documentCache = DashboardReviewFileDiffDocumentCache()"
      )
    )
    #expect(detailSource.contains("documentCache: documentCache"))
    #expect(contentSource.contains("documentCache.document("))
    #expect(contentSource.contains("tabWidth: preferences.snapshot.filesTabWidth"))
    #expect(cacheSource.contains("final class DashboardReviewFileDiffDocumentCache"))
    #expect(splitSource.contains("document: DashboardReviewFileDiffDocument"))
    #expect(unifiedSource.contains("document: DashboardReviewFileDiffDocument"))
    #expect(previewSource.contains("let projectedPatch: ReviewFilePatch"))
    #expect(previewSource.contains("document: document"))
  }

  @Test("file card caches repeated header labels")
  func fileCardCachesRepeatedHeaderLabels() throws {
    let fileCardSource = try dashboardReviewsRouteSource(named: "DashboardReviewFileCard.swift")

    #expect(fileCardSource.contains("private let additionCountLabel: String"))
    #expect(fileCardSource.contains("private let deletionCountLabel: String"))
    #expect(fileCardSource.contains("private let expandAccessibilityLabel: String"))
    #expect(fileCardSource.contains("private let accessibilityLabelText: Text"))
    #expect(!fileCardSource.contains("Text(\"+\\(file.additions)\")"))
    #expect(!fileCardSource.contains("Text(\"-\\(file.deletions)\")"))
    #expect(!fileCardSource.contains("private var accessibilityLabel: Text"))
  }

  @Test("diff grid context menu avoids URL arrays for first thread URL")
  func diffGridContextMenuAvoidsURLArraysForFirstThreadURL() throws {
    let gridSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFileDiffGrid+Viewport.swift")

    #expect(gridSource.contains("func firstThreadURL(forRowID rowID: Int) -> String?"))
    #expect(!gridSource.contains("compactMap(\\.url).first"))
  }

  @Test("diff parser streams patch lines without upfront string array")
  func diffParserStreamsPatchLinesWithoutUpfrontStringArray() throws {
    let documentSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewFileDiffDocument.swift"
    )

    #expect(documentSource.contains("private static func forEachPatchLine("))
    #expect(documentSource.contains("body(patch[lineStart..<lineEnd])"))
    #expect(documentSource.contains("rows.reserveCapacity(estimatedLineCount)"))
    #expect(documentSource.contains("longestCodeCharacterCount = parsed.longestCodeCharacterCount"))
    #expect(
      !documentSource.contains(
        ".split(separator: \"\\n\", omittingEmptySubsequences: false).map(String.init)"
      )
    )
    #expect(!documentSource.contains("rows.map(\\.text.count).max()"))
    #expect(!documentSource.contains("private static func splitPatchLines"))
  }

  @Test("review task keys avoid transient colon join arrays")
  func reviewTaskKeysAvoidTransientColonJoinArrays() throws {
    let files = [
      "DashboardReviewConversationFeed.swift",
      "DashboardReviewDetailView.swift",
      "DashboardReviewFilesModeContentPane.swift",
      "DashboardReviewFilesModeDetailPane.swift",
    ]

    for file in files {
      let source = try dashboardReviewsRouteSource(named: file)
      #expect(!source.contains("].joined(separator: \":\")"))
    }
  }

  @Test("visual status sentences avoid transient join arrays")
  func visualStatusSentencesAvoidTransientJoinArrays() throws {
    let visualsSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsVisualComponents.swift"
    )

    // The sentence builder now assembles a typed reason enum array rather than
    // appending into an inout String, but the contract intent is unchanged:
    // no transient [String] accumulation/join for the status sentence.
    #expect(
      visualsSource.contains("private var attentionReasons: [DashboardReviewAttentionReason]"))
    #expect(!visualsSource.contains("var parts: [String]"))
    #expect(!visualsSource.contains("var reasons: [String]"))
    #expect(!visualsSource.contains("parts.joined(separator: \", \")"))
    #expect(!visualsSource.contains("reasons.joined(separator: \" \")"))
  }

  @Test("provenance labels avoid transient join arrays")
  func provenanceLabelsAvoidTransientJoinArrays() throws {
    let provenanceSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsProvenance.swift"
    )

    #expect(!provenanceSource.contains("parts.joined(separator: \" · \")"))
    #expect(!provenanceSource.contains("repositories.prefix(3).joined(separator: \", \")"))
  }

  @Test("provenance snapshot precomputes body labels")
  func provenanceSnapshotPrecomputesBodyLabels() throws {
    let provenanceSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsProvenance.swift"
    )

    #expect(provenanceSource.contains("let fetchedAgeTitle: String"))
    #expect(provenanceSource.contains("let detailTitle: String"))
    #expect(!provenanceSource.contains("var fetchedAgeTitle: String"))
    #expect(!provenanceSource.contains("var detailTitle: String"))
    #expect(!provenanceSource.contains("localizedString(for: fetchedDate, relativeTo: .now)"))
  }

  @Test("scheduler dispatch keeps per-tick candidate selection bounded")
  func schedulerDispatchKeepsPerTickCandidateSelectionBounded() throws {
    let schedulerSource = try dashboardReviewsRouteSource(named: "DashboardReviewsScheduler.swift")

    #expect(schedulerSource.contains("DashboardReviewsDispatchCandidate"))
    #expect(schedulerSource.contains("insertSortedByDispatchPriority"))
    #expect(schedulerSource.contains("candidates.reserveCapacity(limit + 1)"))
    #expect(!schedulerSource.contains(".filter { !repositoriesInFlight.contains($0) }"))
    #expect(!schedulerSource.contains(".sorted { lhs, rhs in"))
  }

  @Test("repository section header avoids explicit relative formatter work in body")
  func repositorySectionHeaderAvoidsExplicitRelativeFormatterWorkInBody() throws {
    let headerSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRepositorySectionHeader.swift"
    )

    // The header renders relative sync time via a pure-arithmetic label helper,
    // so the body never allocates or runs a relative date formatter.
    #expect(
      headerSource.contains("dashboardReviewsRepositorySectionHeaderRelativeSyncDisplayLabel(")
    )
    #expect(!headerSource.contains("RelativeDateTimeFormatter"))
    #expect(!headerSource.contains("reviewsRelativeFormatter.localizedString"))
    #expect(!headerSource.contains("relativeTo: .now"))
  }
}
