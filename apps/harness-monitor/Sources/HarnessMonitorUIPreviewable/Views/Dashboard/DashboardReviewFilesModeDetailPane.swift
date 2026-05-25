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
  @State private var threadIndexCache = DashboardReviewFileThreadIndexCache()
  @State private var documentCache = DashboardReviewFileDiffDocumentCache()
  /// Per-session override of the Settings default; `nil` falls back to the
  /// stored preference. Driven by the in-view toggle and the ⌘⌥⇧C command.
  @State private var conversationVisibilityOverride: ConversationVisibility?

  var body: some View {
    let timeline = store.reviewTimelineViewModel(for: item.pullRequestID)
    let threadIndex = threadIndexCache.index(for: timeline)
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
    .harnessFocusedSceneValue(
      \.dashboardReviewFilesConversationCommand,
      DashboardReviewFilesConversationCommand(
        currentTitle: effectiveConversationVisibility.menuTitle,
        cycle: cycleConversationVisibility
      )
    )
  }

  var effectiveConversationVisibility: ConversationVisibility {
    conversationVisibilityOverride ?? preferences.snapshot.filesConversationVisibility
  }

  func cycleConversationVisibility() {
    conversationVisibilityOverride = effectiveConversationVisibility.cycledNext
  }

  private var selectedTaskID: String {
    let connection = store.connectionState == .online ? "online" : "offline"
    return "\(item.pullRequestID):\(viewModel.selectedPath ?? ""):\(connection)"
  }

  private func selectedFileView(
    file: ReviewFile,
    threadIndex: DashboardReviewFileThreadIndex
  ) -> some View {
    let fileThreads = threadIndex.threads(forPath: file.path)
    let threads = fileThreads.map(\.anchor)
    return VStack(spacing: 0) {
      header(file: file, threads: threads)
      Divider()
      DashboardReviewFileDiffContent(
        item: item,
        viewModel: viewModel,
        file: file,
        threads: threads,
        documentCache: documentCache
      )
      .environment(
        \.reviewInlineConversationContext,
        conversationContext(file: file, threads: fileThreads)
      )
      .environment(
        \.reviewLineSelectionContext,
        DashboardReviewLineSelectionContext(
          deepLinkID: item.pullRequestDeepLinkID,
          selection: viewModel.lineSelection,
          onSelectLines: { viewModel.selectLines($0) }
        )
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func header(
    file: ReviewFile,
    threads: [DashboardReviewFileThreadAnchor]
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 12) {
        headerSummary(file: file)
        Spacer(minLength: 12)
        headerControls(file: file, threads: threads)
          .fixedSize(horizontal: true, vertical: false)
      }
      VStack(alignment: .leading, spacing: 10) {
        headerSummary(file: file)
        headerControls(file: file, threads: threads)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func headerSummary(file: ReviewFile) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Button(action: onBack) {
        Label("Overview", systemImage: "chevron.left")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)

      VStack(alignment: .leading, spacing: 2) {
        Text(file.path)
          .font(HarnessMonitorTextSize.scaledFont(.headline.monospaced(), by: fontScale))
          .lineLimit(1)
          .truncationMode(.middle)
        HStack(spacing: 8) {
          Text(verbatim: "\(item.repository) #\(item.number)")
            .font(.caption)
            .foregroundStyle(.secondary)
          changeCounts(file)
        }
      }
    }
  }

  @ViewBuilder
  private func headerControls(
    file: ReviewFile,
    threads: [DashboardReviewFileThreadAnchor]
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 10) {
        displayControls
        groupDivider
        viewedButton(file: file)
        groupDivider
        secondaryActions(file: file, threads: threads)
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .center, spacing: 10) {
          displayControls
          groupDivider
          viewedButton(file: file)
        }
        secondaryActions(file: file, threads: threads)
      }
    }
  }

  private var displayControls: some View {
    HStack(alignment: .center, spacing: 10) {
      conversationVisibilityToggle
      softWrapToggle
      viewModePicker
    }
  }

  private var groupDivider: some View {
    Divider()
      .frame(height: 20)
  }

  private func changeCounts(_ file: ReviewFile) -> some View {
    HStack(spacing: 4) {
      Text("+\(file.additions)").foregroundStyle(.green)
      Text("-\(file.deletions)").foregroundStyle(.red)
    }
    .font(.caption.monospacedDigit())
  }

  private var viewModePicker: some View {
    HStack(alignment: .center, spacing: 8) {
      Text("Layout")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack(spacing: 6) {
        viewModeButton(.unified)
        viewModeButton(.split)
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewFilesViewModePicker)
  }

  private func viewModeButton(_ mode: FilesViewMode) -> some View {
    let isSelected = viewModeBinding.wrappedValue == mode
    return Button(action: { viewModeBinding.wrappedValue = mode }) {
      Text(viewModeLabel(for: mode))
        .lineLimit(1)
    }
    .harnessFilterChipButtonStyle(isSelected: isSelected)
    .help(
      isSelected
        ? "\(viewModeLabel(for: mode)) layout selected"
        : "Use \(viewModeLabel(for: mode).lowercased()) diff layout"
    )
    .accessibilityLabel("\(viewModeLabel(for: mode)) layout")
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
  }

  private var softWrapToggle: some View {
    Button(action: { softWrapBinding.wrappedValue = !softWrapBinding.wrappedValue }) {
      Text("Wrap")
        .lineLimit(1)
    }
    .harnessFilterChipButtonStyle(isSelected: softWrapBinding.wrappedValue)
    .help(
      softWrapBinding.wrappedValue
        ? "Soft wrap long diff lines is on"
        : "Soft wrap long diff lines is off"
    )
    .accessibilityLabel("Wrap diff lines")
    .accessibilityValue(softWrapBinding.wrappedValue ? "On" : "Off")
    .accessibilityIdentifier("dashboardReviewFilesDetailSoftWrapToggle")
  }

  private func viewedButton(file: ReviewFile) -> some View {
    let isViewed = isFileViewed(file)
    return Button(action: { markViewed(file: file, viewed: !isViewed) }) {
      Label("Viewed", systemImage: isViewed ? "checkmark.circle.fill" : "checkmark.circle")
        .lineLimit(1)
    }
    .harnessFilterChipButtonStyle(isSelected: isViewed)
    .help(viewedHelpText(for: file))
    .accessibilityLabel("Viewed")
    .accessibilityValue(isViewed ? "On" : "Off")
    .disabled(!viewModel.viewerCanMarkViewed)
  }

  private func secondaryActions(
    file: ReviewFile,
    threads: [DashboardReviewFileThreadAnchor]
  ) -> some View {
    HStack(alignment: .center, spacing: 10) {
      DashboardReviewActionButton(
        title: "Add comment",
        systemImage: "plus.bubble",
        prominence: .secondary,
        helpText: "Comment on the first changed line",
        action: { commentDraft = firstChangedLineDraft(file: file) }
      )
      .accessibilityLabel("Comment on first changed line")
      fileActionsMenu(file: file, threads: threads)
    }
  }

  private var viewModeBinding: Binding<FilesViewMode> {
    Binding(
      get: { preferences.snapshot.filesDefaultViewMode },
      set: { mode in preferences.update { $0.filesDefaultViewModeRaw = mode.rawValue } }
    )
  }

  private var softWrapBinding: Binding<Bool> {
    Binding(
      get: { preferences.snapshot.filesSoftWrapEnabled },
      set: { enabled in preferences.update { $0.filesSoftWrapEnabled = enabled } }
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
    threads: [DashboardReviewFileThreadAnchor]
  ) -> some View {
    Menu {
      Button("Copy Path") { HarnessMonitorClipboard.copy(file.path) }
      if let url = fileURL(file) {
        Button("Copy GitHub Link") { HarnessMonitorClipboard.copy(url.absoluteString) }
        Button("Open on GitHub") { openURL(url) }
      }
      if threads.contains(where: { $0.url != nil }) {
        Divider()
        Button("Copy Thread URLs") {
          copyThreadURLs(threads)
        }
      }
    } label: {
      Label("More", systemImage: "ellipsis.circle")
        .lineLimit(1)
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .fixedSize(horizontal: true, vertical: true)
    .help("Show more file actions")
    .accessibilityLabel("More file actions")
  }

  private func copyThreadURLs(_ threads: [DashboardReviewFileThreadAnchor]) {
    var urls: [String] = []
    urls.reserveCapacity(threads.count)
    for thread in threads {
      if let url = thread.url {
        urls.append(url)
      }
    }
    HarnessMonitorClipboard.copy(urls.joined(separator: "\n"))
  }

  private func fileURL(_ file: ReviewFile) -> URL? {
    dashboardReviewFileBlobURL(
      repositoryFullName: viewModel.repositoryFullName,
      headRefOid: viewModel.headRefOid,
      path: file.path
    )
  }

  private func firstChangedLineDraft(file: ReviewFile) -> DashboardReviewFileCommentDraft? {
    let patch = loadedPatch(for: file) ?? loadedPreviewPatch(for: file)
    let document = patch.map {
      DashboardReviewFileDiffDocument(
        patch: $0,
        language: file.languageHint,
        tabWidth: preferences.snapshot.filesTabWidth
      )
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

  private func isFileViewed(_ file: ReviewFile) -> Bool {
    (viewModel.viewedByPath[file.path] ?? file.viewerViewedState) == .viewed
  }

  private func viewedHelpText(for file: ReviewFile) -> String {
    isFileViewed(file) ? "Mark file unviewed" : "Mark file viewed"
  }

  private func viewModeLabel(for mode: FilesViewMode) -> String {
    switch mode {
    case .unified: "Unified"
    case .split: "Split"
    }
  }
}
