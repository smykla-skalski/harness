import HarnessMonitorKit
import SwiftUI

extension DashboardReviewFilesModeDetailPane {
  @ViewBuilder
  func diffBody(
    file: ReviewFile,
    threads: [DashboardReviewFileThreadAnchor]
  ) -> some View {
    switch viewModel.patches[file.path] ?? .notLoaded {
    case .loaded(let patch):
      renderedPatch(file: file, patch: patch, threads: threads)
    case .loading:
      if case .loaded(let preview) = viewModel.previews[file.path] ?? .notLoaded {
        renderedPreview(file: file, preview: preview, threads: threads, isLoading: true)
      } else {
        ProgressView("Loading file…").controlSize(.small)
      }
    case .notLoaded:
      previewOrProgress(file: file, threads: threads)
    case .failed(let message):
      if case .loaded(let preview) = viewModel.previews[file.path] ?? .notLoaded {
        renderedPreview(file: file, preview: preview, threads: threads, isLoading: false)
      }
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.orange)
    }
  }

  @ViewBuilder
  private func previewOrProgress(
    file: ReviewFile,
    threads: [DashboardReviewFileThreadAnchor]
  ) -> some View {
    switch viewModel.previews[file.path] ?? .notLoaded {
    case .loaded(let preview):
      renderedPreview(file: file, preview: preview, threads: threads, isLoading: false)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.orange)
    case .notLoaded, .loading:
      ProgressView("Preparing preview…").controlSize(.small)
    }
  }

  @ViewBuilder
  private func renderedPatch(
    file: ReviewFile,
    patch: ReviewFilePatch,
    threads: [DashboardReviewFileThreadAnchor]
  ) -> some View {
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
    file: ReviewFile,
    preview: ReviewFilePreview,
    threads: [DashboardReviewFileThreadAnchor],
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

  /// Builds the parsed diff document at the user's configured Files tab width,
  /// going through the per-pane cache so repeated renders reuse the same parse.
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
