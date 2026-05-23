import HarnessMonitorKit
import SwiftUI

/// Unified source-diff renderer backed by an AppKit line grid. The
/// incoming daemon payload is still a unified patch for compatibility,
/// but rendering is source-aware: gutters, prefixes, and code text are
/// parsed into rows and only visible rows are highlighted/drawn.
struct DashboardReviewFileDiffUnified: View {
  let patch: ReviewFilePatch
  let language: HarnessReviewFileLanguage
  let fontScale: CGFloat
  let threads: [DashboardReviewFileThreadAnchor]
  let repositoryFullName: String?
  let document: DashboardReviewFileDiffDocument
  let captionFont: Font
  let caption2Font: Font
  let diffFont: Font

  init(
    patch: ReviewFilePatch,
    language: HarnessReviewFileLanguage,
    fontScale: CGFloat,
    threads: [DashboardReviewFileThreadAnchor] = [],
    repositoryFullName: String? = nil
  ) {
    self.patch = patch
    self.language = language
    self.fontScale = fontScale
    self.threads = threads
    self.repositoryFullName = repositoryFullName
    document = DashboardReviewFileDiffDocument(patch: patch, language: language)
    captionFont = HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
    caption2Font = HarnessMonitorTextSize.scaledFont(.caption2, by: fontScale)
    diffFont = DashboardReviewDiffTypography.font(for: fontScale)
  }

  var body: some View {
    if document.isEmpty {
      Text("No patch content").font(captionFont).foregroundStyle(.secondary)
    } else {
      DashboardReviewFileDiffGrid(
        document: document,
        viewMode: .unified,
        fontScale: fontScale,
        threads: threads,
        repositoryFullName: repositoryFullName
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(
        height: DashboardReviewFileDiffGrid.viewportHeight(
          rowCount: document.rows.count,
          fontScale: fontScale
        )
      )
      .font(diffFont)
      .accessibilityIdentifier("dashboardReviewFileDiffUnified")
      if patch.truncated {
        Text("Truncated by GitHub at 3000 lines. Open the PR on github.com for the full diff.")
          .font(caption2Font)
          .foregroundStyle(.orange)
      }
    }
  }
}
