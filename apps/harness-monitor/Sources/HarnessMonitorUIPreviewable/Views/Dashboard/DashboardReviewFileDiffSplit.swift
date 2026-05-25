import HarnessMonitorKit
import SwiftUI

/// Split-view source diff with left (old) and right (new) panes side by
/// side. Uses the same parsed row model as the unified renderer so
/// source highlighting is applied to code text, not to patch prefixes.
struct DashboardReviewFileDiffSplit: View {
  let patch: ReviewFilePatch
  let language: HarnessReviewFileLanguage
  let fontScale: CGFloat
  let softWrapEnabled: Bool
  var minColumnPoints: CGFloat = 280
  let threads: [DashboardReviewFileThreadAnchor]
  let repositoryFullName: String?
  let fillsAvailableSpace: Bool
  let document: DashboardReviewFileDiffDocument
  let diffFont: Font

  @State private var preferredViewportHeight: CGFloat?

  init(
    patch: ReviewFilePatch,
    language: HarnessReviewFileLanguage,
    fontScale: CGFloat,
    softWrapEnabled: Bool = true,
    minColumnPoints: CGFloat = 280,
    threads: [DashboardReviewFileThreadAnchor] = [],
    repositoryFullName: String? = nil,
    fillsAvailableSpace: Bool = false
  ) {
    self.init(
      patch: patch,
      language: language,
      fontScale: fontScale,
      softWrapEnabled: softWrapEnabled,
      minColumnPoints: minColumnPoints,
      threads: threads,
      repositoryFullName: repositoryFullName,
      fillsAvailableSpace: fillsAvailableSpace,
      document: DashboardReviewFileDiffDocument(patch: patch, language: language)
    )
  }

  init(
    patch: ReviewFilePatch,
    language: HarnessReviewFileLanguage,
    fontScale: CGFloat,
    softWrapEnabled: Bool = true,
    minColumnPoints: CGFloat = 280,
    threads: [DashboardReviewFileThreadAnchor],
    repositoryFullName: String?,
    fillsAvailableSpace: Bool,
    document: DashboardReviewFileDiffDocument
  ) {
    self.patch = patch
    self.language = language
    self.fontScale = fontScale
    self.softWrapEnabled = softWrapEnabled
    self.minColumnPoints = minColumnPoints
    self.threads = threads
    self.repositoryFullName = repositoryFullName
    self.fillsAvailableSpace = fillsAvailableSpace
    self.document = document
    diffFont = DashboardReviewDiffTypography.font(for: fontScale)
  }

  var body: some View {
    let height =
      fillsAvailableSpace
      ? nil
      : preferredViewportHeight
        ?? DashboardReviewFileDiffGrid.viewportHeight(
          rowCount: document.rows.count,
          fontScale: fontScale
        )
    GeometryReader { proxy in
      let width = proxy.size.width
      if width / 2 < minColumnPoints {
        DashboardReviewFileDiffUnified(
          patch: patch,
          language: language,
          fontScale: fontScale,
          softWrapEnabled: softWrapEnabled,
          threads: threads,
          repositoryFullName: repositoryFullName,
          fillsAvailableSpace: fillsAvailableSpace,
          document: document,
          onPreferredViewportHeightChange: { preferredViewportHeight = $0 }
        )
      } else {
        DashboardReviewFileDiffGrid(
          document: document,
          viewMode: .split,
          fontScale: fontScale,
          softWrapEnabled: softWrapEnabled,
          threads: threads,
          repositoryFullName: repositoryFullName,
          onPreferredViewportHeightChange: { preferredViewportHeight = $0 }
        )
        .font(diffFont)
      }
    }
    .frame(
      maxWidth: .infinity,
      maxHeight: fillsAvailableSpace ? .infinity : nil,
      alignment: .leading
    )
    .frame(
      height: height
    )
    .accessibilityIdentifier("dashboardReviewFileDiffSplit")
  }
}
