import HarnessMonitorKit
import SwiftUI

struct DashboardReviewFilesModeDetailPane: View {
  let item: ReviewItem
  let viewModel: ReviewFilesViewModel
  let store: HarnessMonitorStore
  let viewerLogin: String?
  let onBack: () -> Void
  let onSelectPath: (String?) -> Void

  @Environment(\.reviewsPreferences)
  private var preferences
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.openURL)
  private var openURL
  @State private var commentDraft: DashboardReviewFileCommentDraft?

  var body: some View {
    let timeline = store.reviewTimelineViewModel(for: item.pullRequestID)
    let threadIndex = DashboardReviewFileThreadIndex(entries: timeline.entries)
    Group {
      if let file = viewModel.selectedFile {
        selectedFileView(file: file, threadIndex: threadIndex)
      } else {
        ContentUnavailableView {
          Label("Select a file", systemImage: "doc.text.magnifyingglass")
        } description: {
          Text("Choose a changed file from the file tree")
        }
      }
    }
    .task(id: selectedTaskID) {
      await loadSelectedFile()
    }
    .sheet(item: $commentDraft) { draft in
      DashboardReviewInlineCommentSheet(
        draft: draft,
        viewerLogin: viewerLogin,
        onCancel: { commentDraft = nil },
        onSend: { body in
          await postInlineComment(draft: draft, body: body)
        }
      )
    }
    .accessibilityIdentifier("dashboardReviewFilesModeDetailPane")
  }

  private var selectedTaskID: String {
    [
      item.pullRequestID,
      viewModel.selectedPath ?? "",
      store.connectionState == .online ? "online" : "offline",
    ].joined(separator: ":")
  }

  private func selectedFileView(
    file: ReviewFile,
    threadIndex: DashboardReviewFileThreadIndex
  ) -> some View {
    VStack(spacing: 0) {
      header(file: file, threadIndex: threadIndex)
      Divider()
      diffBody(file: file, threads: threadIndex.anchors(forPath: file.path))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func header(
    file: ReviewFile,
    threadIndex: DashboardReviewFileThreadIndex
  ) -> some View {
    HStack(spacing: 10) {
      Button(action: onBack) {
        Label("Overview", systemImage: "chevron.left")
      }
      .controlSize(.small)
      VStack(alignment: .leading, spacing: 2) {
        Text(file.path)
          .font(HarnessMonitorTextSize.scaledFont(.headline.monospaced(), by: fontScale))
          .lineLimit(1)
          .truncationMode(.middle)
        Text("\(item.repository) #\(item.number)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      changeCounts(file)
      viewModePicker
      Button {
        commentDraft = firstChangedLineDraft(file: file)
      } label: {
        Image(systemName: "plus.bubble")
      }
      .harnessPlainButtonStyle()
      .help("Comment on the first changed line")
      .accessibilityLabel("Comment on first changed line")
      fileActionsMenu(file: file, threadIndex: threadIndex)
      Toggle(
        "Viewed",
        isOn: Binding(
          get: { (viewModel.viewedByPath[file.path] ?? file.viewerViewedState) == .viewed },
          set: { markViewed(file: file, viewed: $0) }
        )
      )
      .toggleStyle(.checkbox)
      .controlSize(.small)
      .disabled(!viewModel.viewerCanMarkViewed)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func changeCounts(_ file: ReviewFile) -> some View {
    HStack(spacing: 4) {
      Text("+\(file.additions)").foregroundStyle(.green)
      Text("-\(file.deletions)").foregroundStyle(.red)
    }
    .font(.caption.monospacedDigit())
  }

  private var viewModePicker: some View {
    Picker("Diff layout", selection: viewModeBinding) {
      Text("Unified").tag(FilesViewMode.unified)
      Text("Split").tag(FilesViewMode.split)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .controlSize(.small)
    .frame(width: 150)
  }

  @ViewBuilder
  private func diffBody(
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
        threads: threads,
        repositoryFullName: viewModel.repositoryFullName,
        fillsAvailableSpace: true
      )
    } else {
      DashboardReviewFileDiffUnified(
        patch: patch,
        language: file.languageHint,
        fontScale: fontScale,
        threads: threads,
        repositoryFullName: viewModel.repositoryFullName,
        fillsAvailableSpace: true
      )
    }
  }

  private func renderedPreview(
    file: ReviewFile,
    preview: ReviewFilePreview,
    threads: [DashboardReviewFileThreadAnchor],
    isLoading: Bool
  ) -> some View {
    DashboardReviewFileDiffPreview(
      preview: preview,
      viewMode: preferences.snapshot.filesDefaultViewMode,
      language: file.languageHint,
      fontScale: fontScale,
      threads: threads,
      repositoryFullName: viewModel.repositoryFullName,
      isLoadingFullPatch: isLoading,
      fullPatchFailed: (viewModel.patches[file.path] ?? .notLoaded).isFailedForFilesMode,
      fillsAvailableSpace: true
    )
  }

  private var viewModeBinding: Binding<FilesViewMode> {
    Binding(
      get: { preferences.snapshot.filesDefaultViewMode },
      set: { mode in preferences.update { $0.filesDefaultViewModeRaw = mode.rawValue } }
    )
  }

  private func loadSelectedFile() async {
    guard let file = viewModel.selectedFile, store.connectionState == .online else { return }
    let interval = ReviewFilesPerf.beginSelectedFileFirstRows(path: file.path)
    await store.preparePatchPreviews(
      forPullRequest: item.pullRequestID,
      paths: [file.path],
      largeDiffStrategy: preferences.snapshot.filesLargeDiffStrategy
    )
    ReviewFilesPerf.end(interval)
    await store.preparePatches(
      forPullRequest: item.pullRequestID,
      paths: [file.path],
      largeDiffStrategy: preferences.snapshot.filesLargeDiffStrategy
    )
  }

  private func markViewed(file: ReviewFile, viewed: Bool) {
    store.setFileViewed(
      pullRequestID: item.pullRequestID,
      path: file.path,
      viewed: viewed
    )
  }

  private func fileActionsMenu(
    file: ReviewFile,
    threadIndex: DashboardReviewFileThreadIndex
  ) -> some View {
    Menu {
      Button("Copy Path") { HarnessMonitorClipboard.copy(file.path) }
      if let url = fileURL(file) {
        Button("Copy GitHub Link") { HarnessMonitorClipboard.copy(url.absoluteString) }
        Button("Open on GitHub") { openURL(url) }
      }
      let urls = threadIndex.anchors(forPath: file.path).compactMap(\.url)
      if !urls.isEmpty {
        Divider()
        Button("Copy Thread URLs") {
          HarnessMonitorClipboard.copy(urls.joined(separator: "\n"))
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .frame(width: 28, height: 28)
    }
    .menuStyle(.borderlessButton)
    .help("File actions")
  }

  private func fileURL(_ file: ReviewFile) -> URL? {
    guard let repository = viewModel.repositoryFullName, !viewModel.headRefOid.isEmpty else {
      return nil
    }
    let encodedPath = file.path.dashboardReviewGitHubPathEncoded
    let urlString =
      "https://github.com/\(repository)/blob/\(viewModel.headRefOid)/\(encodedPath)"
    return URL(string: urlString)
  }

  private func firstChangedLineDraft(file: ReviewFile) -> DashboardReviewFileCommentDraft? {
    let patch = loadedPatch(for: file) ?? loadedPreviewPatch(for: file)
    let document = patch.map {
      DashboardReviewFileDiffDocument(patch: $0, language: file.languageHint)
    }
    let row = document?.rows.first {
      $0.newLine != nil && ($0.kind == .addition || $0.kind == .context)
    }
    guard let row, let line = row.newLine else { return nil }
    return .newThread(file: file, line: line, side: .new)
  }

  private func loadedPatch(for file: ReviewFile) -> ReviewFilePatch? {
    if case .loaded(let patch) = viewModel.patches[file.path] ?? .notLoaded {
      return patch
    }
    return nil
  }

  private func loadedPreviewPatch(for file: ReviewFile) -> ReviewFilePatch? {
    if case .loaded(let preview) = viewModel.previews[file.path] ?? .notLoaded {
      return preview.projectedPatch
    }
    return nil
  }

  private func postInlineComment(
    draft: DashboardReviewFileCommentDraft,
    body: String
  ) async {
    commentDraft = nil
    await store.postReviewFileComment(
      pullRequestID: item.pullRequestID,
      repository: item.repository,
      draft: draft,
      body: body,
      viewerLogin: viewerLogin
    )
  }
}

extension ReviewFilePatchState {
  fileprivate var isFailedForFilesMode: Bool {
    if case .failed = self { return true }
    return false
  }
}
