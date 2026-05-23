import HarnessMonitorKit
import SwiftUI

/// Split-view source diff with left (old) and right (new) panes side by
/// side. Uses the same parsed row model as the unified renderer so
/// source highlighting is applied to code text, not to patch prefixes.
struct DashboardReviewFileDiffSplit: View {
  let patch: ReviewFilePatch
  let language: HarnessReviewFileLanguage
  let fontScale: CGFloat
  var minColumnPoints: CGFloat = 280
  let threads: [DashboardReviewFileThreadAnchor]
  let repositoryFullName: String?
  let document: DashboardReviewFileDiffDocument
  let diffFont: Font

  init(
    patch: ReviewFilePatch,
    language: HarnessReviewFileLanguage,
    fontScale: CGFloat,
    minColumnPoints: CGFloat = 280,
    threads: [DashboardReviewFileThreadAnchor] = [],
    repositoryFullName: String? = nil
  ) {
    self.patch = patch
    self.language = language
    self.fontScale = fontScale
    self.minColumnPoints = minColumnPoints
    self.threads = threads
    self.repositoryFullName = repositoryFullName
    document = DashboardReviewFileDiffDocument(patch: patch, language: language)
    diffFont = DashboardReviewDiffTypography.font(for: fontScale)
  }

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      if width / 2 < minColumnPoints {
        DashboardReviewFileDiffUnified(
          patch: patch,
          language: language,
          fontScale: fontScale
        )
      } else {
        DashboardReviewFileDiffGrid(
          document: document,
          viewMode: .split,
          fontScale: fontScale,
          threads: threads,
          repositoryFullName: repositoryFullName
        )
        .font(diffFont)
      }
    }
    .frame(
      height: DashboardReviewFileDiffGrid.viewportHeight(
        rowCount: document.rows.count,
        fontScale: fontScale
      )
    )
    .accessibilityIdentifier("dashboardReviewFileDiffSplit")
  }
}
