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
  let softWrapEnabled: Bool
  let threads: [DashboardReviewFileThreadAnchor]
  let repositoryFullName: String?
  let fillsAvailableSpace: Bool
  let document: DashboardReviewFileDiffDocument
  let onPreferredViewportHeightChange: (@MainActor (CGFloat) -> Void)?
  let captionFont: Font
  let caption2Font: Font
  let diffFont: Font

  @State private var preferredViewportHeight: CGFloat?

  init(
    patch: ReviewFilePatch,
    language: HarnessReviewFileLanguage,
    fontScale: CGFloat,
    softWrapEnabled: Bool = true,
    threads: [DashboardReviewFileThreadAnchor] = [],
    repositoryFullName: String? = nil,
    fillsAvailableSpace: Bool = false
  ) {
    self.init(
      patch: patch,
      language: language,
      fontScale: fontScale,
      softWrapEnabled: softWrapEnabled,
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
    threads: [DashboardReviewFileThreadAnchor],
    repositoryFullName: String?,
    fillsAvailableSpace: Bool,
    document: DashboardReviewFileDiffDocument,
    onPreferredViewportHeightChange: (@MainActor (CGFloat) -> Void)? = nil
  ) {
    self.patch = patch
    self.language = language
    self.fontScale = fontScale
    self.softWrapEnabled = softWrapEnabled
    self.threads = threads
    self.repositoryFullName = repositoryFullName
    self.fillsAvailableSpace = fillsAvailableSpace
    self.document = document
    self.onPreferredViewportHeightChange = onPreferredViewportHeightChange
    captionFont = HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
    caption2Font = HarnessMonitorTextSize.scaledFont(.caption2, by: fontScale)
    diffFont = DashboardReviewDiffTypography.font(for: fontScale)
  }

  var body: some View {
    if document.isEmpty {
      Text("No patch content").font(captionFont).foregroundStyle(.secondary)
    } else {
      VStack(alignment: .leading, spacing: 0) {
        grid
        if patch.truncated {
          Text("Truncated by GitHub at 3000 lines. Open the PR on github.com for the full diff.")
            .font(caption2Font)
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
      }
      .frame(
        maxWidth: .infinity,
        maxHeight: fillsAvailableSpace ? .infinity : nil,
        alignment: .topLeading
      )
      .accessibilityIdentifier("dashboardReviewFileDiffUnified")
    }
  }

  private var grid: some View {
    let height =
      fillsAvailableSpace
      ? nil
      : preferredViewportHeight
        ?? DashboardReviewFileDiffGrid.viewportHeight(
          rowCount: document.rows.count,
          fontScale: fontScale
        )
    return
      DashboardReviewFileDiffGrid(
        document: document,
        viewMode: .unified,
        fontScale: fontScale,
        softWrapEnabled: softWrapEnabled,
        threads: threads,
        repositoryFullName: repositoryFullName,
        onPreferredViewportHeightChange: { height in
          preferredViewportHeight = height
          onPreferredViewportHeightChange?(height)
        }
      )
      .frame(
        maxWidth: .infinity,
        maxHeight: fillsAvailableSpace ? .infinity : nil,
        alignment: .leading
      )
      .frame(
        height: height
      )
      .font(diffFont)
  }
}
