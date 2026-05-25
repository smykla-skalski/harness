import HarnessMonitorKit
import SwiftUI

/// First-lines diff renderer that reuses the full diff highlighter while
/// the daemon fetches the remaining patch body in the background.
struct DashboardReviewFileDiffPreview: View {
  let preview: ReviewFilePreview
  let projectedPatch: ReviewFilePatch
  let viewMode: FilesViewMode
  let language: HarnessReviewFileLanguage
  let fontScale: CGFloat
  let softWrapEnabled: Bool
  var threads: [DashboardReviewFileThreadAnchor] = []
  var repositoryFullName: String?
  let isLoadingFullPatch: Bool
  let fullPatchFailed: Bool
  var fillsAvailableSpace: Bool = false
  let document: DashboardReviewFileDiffDocument

  init(
    preview: ReviewFilePreview,
    viewMode: FilesViewMode,
    language: HarnessReviewFileLanguage,
    fontScale: CGFloat,
    softWrapEnabled: Bool = true,
    threads: [DashboardReviewFileThreadAnchor] = [],
    repositoryFullName: String? = nil,
    isLoadingFullPatch: Bool,
    fullPatchFailed: Bool,
    fillsAvailableSpace: Bool = false
  ) {
    let projectedPatch = preview.projectedPatch
    self.init(
      preview: preview,
      projectedPatch: projectedPatch,
      viewMode: viewMode,
      language: language,
      fontScale: fontScale,
      softWrapEnabled: softWrapEnabled,
      threads: threads,
      repositoryFullName: repositoryFullName,
      isLoadingFullPatch: isLoadingFullPatch,
      fullPatchFailed: fullPatchFailed,
      fillsAvailableSpace: fillsAvailableSpace,
      document: DashboardReviewFileDiffDocument(patch: projectedPatch, language: language)
    )
  }

  init(
    preview: ReviewFilePreview,
    projectedPatch: ReviewFilePatch,
    viewMode: FilesViewMode,
    language: HarnessReviewFileLanguage,
    fontScale: CGFloat,
    softWrapEnabled: Bool = true,
    threads: [DashboardReviewFileThreadAnchor],
    repositoryFullName: String?,
    isLoadingFullPatch: Bool,
    fullPatchFailed: Bool,
    fillsAvailableSpace: Bool,
    document: DashboardReviewFileDiffDocument
  ) {
    self.preview = preview
    self.projectedPatch = projectedPatch
    self.viewMode = viewMode
    self.language = language
    self.fontScale = fontScale
    self.softWrapEnabled = softWrapEnabled
    self.threads = threads
    self.repositoryFullName = repositoryFullName
    self.isLoadingFullPatch = isLoadingFullPatch
    self.fullPatchFailed = fullPatchFailed
    self.fillsAvailableSpace = fillsAvailableSpace
    self.document = document
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if preview.patch.isEmpty {
        Text("No patch preview").font(.caption).foregroundStyle(.secondary)
      } else {
        diffPreview
      }
      footer
    }
    .frame(
      maxWidth: .infinity,
      maxHeight: fillsAvailableSpace ? .infinity : nil,
      alignment: .topLeading
    )
    .accessibilityIdentifier("dashboardReviewFileDiffPreview")
  }

  @ViewBuilder private var diffPreview: some View {
    if viewMode == .split {
      DashboardReviewFileDiffSplit(
        patch: projectedPatch,
        language: language,
        fontScale: fontScale,
        softWrapEnabled: softWrapEnabled,
        threads: threads,
        repositoryFullName: repositoryFullName,
        fillsAvailableSpace: fillsAvailableSpace,
        document: document
      )
    } else {
      DashboardReviewFileDiffUnified(
        patch: projectedPatch,
        language: language,
        fontScale: fontScale,
        softWrapEnabled: softWrapEnabled,
        threads: threads,
        repositoryFullName: repositoryFullName,
        fillsAvailableSpace: fillsAvailableSpace,
        document: document
      )
    }
  }

  @ViewBuilder private var footer: some View {
    if preview.hasMore {
      HStack(spacing: 6) {
        if isLoadingFullPatch {
          ProgressView().controlSize(.mini)
        }
        Text(remainderMessage)
          .font(.caption2)
          .foregroundStyle(fullPatchFailed ? .orange : .secondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
  }

  private var remainderMessage: String {
    if fullPatchFailed {
      return "Showing first \(preview.lineCount) lines; remaining lines are unavailable."
    }
    if isLoadingFullPatch {
      return "Loading remaining lines after the first \(preview.lineCount)."
    }
    return "Showing first \(preview.lineCount) lines."
  }
}
