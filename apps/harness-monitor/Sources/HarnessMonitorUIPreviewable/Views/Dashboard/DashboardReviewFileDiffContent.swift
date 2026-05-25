import HarnessMonitorKit
import SwiftUI

/// Renders the diff body for the selected Reviews file: the split/unified grid,
/// the preview and loading fallbacks, and error states. Extracted from the
/// detail pane so it re-evaluates only when its own inputs change. The parsed
/// document cache is owned by the pane and passed in, so switching files reuses
/// documents; this view reads layout preferences from the environment.
struct DashboardReviewFileDiffContent: View {
  let item: ReviewItem
  let viewModel: ReviewFilesViewModel
  let file: ReviewFile
  let threads: [DashboardReviewFileThreadAnchor]
  let documentCache: DashboardReviewFileDiffDocumentCache

  @Environment(\.reviewsPreferences)
  private var preferences
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    switch viewModel.patches[file.path] ?? .notLoaded {
    case .loaded(let patch):
      renderedPatch(patch: patch)
    case .loading:
      if case .loaded(let preview) = viewModel.previews[file.path] ?? .notLoaded {
        renderedPreview(preview: preview, isLoading: true)
      } else {
        ProgressView("Loading file…").controlSize(.small)
      }
    case .notLoaded:
      previewOrProgress()
    case .failed(let message):
      if case .loaded(let preview) = viewModel.previews[file.path] ?? .notLoaded {
        renderedPreview(preview: preview, isLoading: false)
      }
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.orange)
    }
  }

  @ViewBuilder
  private func previewOrProgress() -> some View {
    switch viewModel.previews[file.path] ?? .notLoaded {
    case .loaded(let preview):
      renderedPreview(preview: preview, isLoading: false)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.orange)
    case .notLoaded, .loading:
      ProgressView("Preparing preview…").controlSize(.small)
    }
  }

  @ViewBuilder
  private func renderedPatch(patch: ReviewFilePatch) -> some View {
    if file.isBinary {
      DashboardReviewFileImagePreview(
        file: file,
        patch: patch,
        pullRequestID: item.pullRequestID,
        repositoryID: item.repositoryID,
        fontScale: fontScale
      )
    } else if preferences.snapshot.filesDefaultViewMode == .split {
      DashboardReviewFileDiffSplit(
        patch: patch,
        language: file.languageHint,
        fontScale: fontScale,
        softWrapEnabled: preferences.snapshot.filesSoftWrapEnabled,
        threads: threads,
        repositoryFullName: viewModel.repositoryFullName,
        fillsAvailableSpace: true,
        document: diffDocument(patch: patch, language: file.languageHint)
      )
    } else {
      DashboardReviewFileDiffUnified(
        patch: patch,
        language: file.languageHint,
        fontScale: fontScale,
        softWrapEnabled: preferences.snapshot.filesSoftWrapEnabled,
        threads: threads,
        repositoryFullName: viewModel.repositoryFullName,
        fillsAvailableSpace: true,
        document: diffDocument(patch: patch, language: file.languageHint)
      )
    }
  }

  private func renderedPreview(
    preview: ReviewFilePreview,
    isLoading: Bool
  ) -> some View {
    let projectedPatch = preview.projectedPatch
    return DashboardReviewFileDiffPreview(
      preview: preview,
      projectedPatch: projectedPatch,
      viewMode: preferences.snapshot.filesDefaultViewMode,
      language: file.languageHint,
      fontScale: fontScale,
      softWrapEnabled: preferences.snapshot.filesSoftWrapEnabled,
      threads: threads,
      repositoryFullName: viewModel.repositoryFullName,
      isLoadingFullPatch: isLoading,
      fullPatchFailed: (viewModel.patches[file.path] ?? .notLoaded).isFailedForFilesMode,
      fillsAvailableSpace: true,
      document: diffDocument(patch: projectedPatch, language: file.languageHint)
    )
  }

  private func diffDocument(
    patch: ReviewFilePatch,
    language: HarnessReviewFileLanguage
  ) -> DashboardReviewFileDiffDocument {
    documentCache.document(
      patch: patch,
      language: language,
      tabWidth: preferences.snapshot.filesTabWidth
    )
  }
}

extension ReviewFilePatchState {
  fileprivate var isFailedForFilesMode: Bool {
    if case .failed = self { return true }
    return false
  }
}
