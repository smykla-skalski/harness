import HarnessMonitorKit
import SwiftUI

/// Value-driven wrapper around `DashboardReviewFileCardInternal`. Keeps
/// the repeated row's inputs explicit so font-scale changes don't add
/// another environment dependency to every file card.
struct DashboardReviewFileCard: View {
  let file: ReviewFile
  let viewedState: ReviewFileViewedState
  let viewerCanMarkViewed: Bool
  let previewState: ReviewFilePreviewState
  let patchState: ReviewFilePatchState
  let viewMode: FilesViewMode
  let softWrapEnabled: Bool
  let pullRequestID: String
  let repositoryID: String
  let repositoryFullName: String?
  let headRefOid: String
  let fontScale: CGFloat
  let threads: [DashboardReviewFileThreadAnchor]
  let onToggleViewed: @MainActor (Bool) -> Void
  let onLoadPreview: @MainActor () -> Void
  let onLoadPatch: @MainActor () -> Void

  var body: some View {
    DashboardReviewFileCardInternal(
      file: file,
      viewedState: viewedState,
      viewerCanMarkViewed: viewerCanMarkViewed,
      previewState: previewState,
      patchState: patchState,
      viewMode: viewMode,
      softWrapEnabled: softWrapEnabled,
      pullRequestID: pullRequestID,
      repositoryID: repositoryID,
      repositoryFullName: repositoryFullName,
      headRefOid: headRefOid,
      fontScale: fontScale,
      threads: threads,
      onToggleViewed: onToggleViewed,
      onLoadPreview: onLoadPreview,
      onLoadPatch: onLoadPatch
    )
  }
}

struct DashboardReviewFileCardInternal: View {
  let file: ReviewFile
  let viewedState: ReviewFileViewedState
  let viewerCanMarkViewed: Bool
  let previewState: ReviewFilePreviewState
  let patchState: ReviewFilePatchState
  let viewMode: FilesViewMode
  let softWrapEnabled: Bool
  let pullRequestID: String
  let repositoryID: String
  let repositoryFullName: String?
  let headRefOid: String
  let fontScale: CGFloat
  let threads: [DashboardReviewFileThreadAnchor]
  let onToggleViewed: @MainActor (Bool) -> Void
  let onLoadPreview: @MainActor () -> Void
  let onLoadPatch: @MainActor () -> Void
  let chevronFont: Font
  let pathFont: Font
  let renameFont: Font
  let changeCountFont: Font
  let errorFont: Font
  private let additionCountLabel: String
  private let deletionCountLabel: String
  private let expandAccessibilityLabel: String
  private let collapseAccessibilityLabel: String
  private let viewedToggleHelp: String
  private let accessibilityLabelText: Text

  @State private var isExpanded: Bool = false
  @Environment(\.openURL)
  var openURL

  init(
    file: ReviewFile,
    viewedState: ReviewFileViewedState,
    viewerCanMarkViewed: Bool,
    previewState: ReviewFilePreviewState,
    patchState: ReviewFilePatchState,
    viewMode: FilesViewMode,
    softWrapEnabled: Bool,
    pullRequestID: String,
    repositoryID: String,
    repositoryFullName: String?,
    headRefOid: String,
    fontScale: CGFloat,
    threads: [DashboardReviewFileThreadAnchor] = [],
    onToggleViewed: @escaping @MainActor (Bool) -> Void,
    onLoadPreview: @escaping @MainActor () -> Void,
    onLoadPatch: @escaping @MainActor () -> Void
  ) {
    self.file = file
    self.viewedState = viewedState
    self.viewerCanMarkViewed = viewerCanMarkViewed
    self.previewState = previewState
    self.patchState = patchState
    self.viewMode = viewMode
    self.softWrapEnabled = softWrapEnabled
    self.pullRequestID = pullRequestID
    self.repositoryID = repositoryID
    self.repositoryFullName = repositoryFullName
    self.headRefOid = headRefOid
    self.fontScale = fontScale
    self.threads = threads
    self.onToggleViewed = onToggleViewed
    self.onLoadPreview = onLoadPreview
    self.onLoadPatch = onLoadPatch
    chevronFont = HarnessMonitorTextSize.scaledFont(
      .caption.weight(.semibold),
      by: fontScale
    )
    pathFont = HarnessMonitorTextSize.scaledFont(.body.monospaced(), by: fontScale)
    renameFont = HarnessMonitorTextSize.scaledFont(.caption2, by: fontScale)
    changeCountFont = HarnessMonitorTextSize.scaledFont(
      .caption.monospacedDigit(),
      by: fontScale
    )
    errorFont = HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
    additionCountLabel = "+\(file.additions)"
    deletionCountLabel = "-\(file.deletions)"
    expandAccessibilityLabel = "Expand \(file.path)"
    collapseAccessibilityLabel = "Collapse \(file.path)"
    viewedToggleHelp = viewedState == .viewed ? "Mark file unviewed" : "Mark file viewed"
    accessibilityLabelText = Text(
      """
      File \(file.path), \(file.additions) additions, \(file.deletions) deletions, \
      \(viewedState == .viewed ? "viewed" : "not viewed")
      """
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if isExpanded {
        patchBody
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .background(
      HarnessMonitorTheme.ink.opacity(0.035),
      in: RoundedRectangle(cornerRadius: 6, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .strokeBorder(HarnessMonitorTheme.ink.opacity(0.10), lineWidth: 1)
    }
    .onChange(of: previewState) { _, _ in
      guard isExpanded else { return }
      loadFullPatchIfPreviewFinished()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabelText)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewFileCard(path: file.path))
  }

  private var header: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        disclosureButton
        pathLabel
        Spacer(minLength: 0)
        headerControls
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {
          disclosureButton
          pathLabel
          Spacer(minLength: 0)
          changeCounts
        }
        HStack(spacing: 10) {
          Spacer(minLength: 40)
          viewedButton
          fileActionsMenu
        }
      }
    }
    .frame(minHeight: 32)
  }

  private var disclosureButton: some View {
    Button(
      action: {
        isExpanded.toggle()
        if isExpanded {
          loadPreviewIfNeeded()
          loadFullPatchIfPreviewFinished()
        }
      },
      label: {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(chevronFont)
          .frame(width: 28, height: 28)
          .contentShape(.rect)
      }
    )
    .buttonStyle(.borderless)
    .help(isExpanded ? "Collapse file diff" : "Expand file diff")
    .accessibilityLabel(isExpanded ? collapseAccessibilityLabel : expandAccessibilityLabel)
  }

  private var headerControls: some View {
    HStack(spacing: 10) {
      changeCounts
      viewedButton
      fileActionsMenu
    }
  }

  private var viewedButton: some View {
    let isViewed = viewedState == .viewed
    return Button(action: { onToggleViewed(!isViewed) }) {
      Label("Viewed", systemImage: isViewed ? "checkmark.circle.fill" : "checkmark.circle")
        .lineLimit(1)
    }
    .harnessFilterChipButtonStyle(isSelected: isViewed)
    .help(viewedToggleHelp)
    .accessibilityLabel("Viewed")
    .accessibilityValue(isViewed ? "On" : "Off")
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.dashboardReviewFileViewedToggle(path: file.path)
    )
    .disabled(!viewerCanMarkViewed)
  }

  private var pathLabel: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(file.path)
        .font(pathFont)
        .lineLimit(1)
        .truncationMode(.middle)
        .layoutPriority(1)
      if let previousPath = file.previousPath, previousPath != file.path {
        Label("renamed from \(previousPath)", systemImage: "arrow.right")
          .labelStyle(.titleAndIcon)
          .font(renameFont)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .truncationMode(.middle)
          .help("renamed from \(previousPath)")
      }
    }
  }

  private var changeCounts: some View {
    HStack(spacing: 4) {
      if file.additions > 0 {
        Text(verbatim: additionCountLabel).foregroundStyle(.green).font(changeCountFont)
      }
      if file.deletions > 0 {
        Text(verbatim: deletionCountLabel).foregroundStyle(.red).font(changeCountFont)
      }
    }
    .frame(minWidth: 58, alignment: .trailing)
  }

  @ViewBuilder private var patchBody: some View {
    switch patchState {
    case .notLoaded:
      previewBody
    case .loading:
      if case .loaded = previewState {
        previewBody
      } else {
        ProgressView().controlSize(.small)
      }
    case .loaded(let patch):
      if file.isBinary {
        DashboardReviewFileImagePreview(
          file: file,
          patch: patch,
          pullRequestID: pullRequestID,
          repositoryID: repositoryID,
          fontScale: fontScale
        )
      } else if viewMode == .split {
        DashboardReviewFileDiffSplit(
          patch: patch,
          language: file.languageHint,
          fontScale: fontScale,
          softWrapEnabled: softWrapEnabled,
          threads: threads,
          repositoryFullName: repositoryFullName
        )
      } else {
        DashboardReviewFileDiffUnified(
          patch: patch,
          language: file.languageHint,
          fontScale: fontScale,
          softWrapEnabled: softWrapEnabled,
          threads: threads,
          repositoryFullName: repositoryFullName
        )
      }
    case .failed:
      if case .loaded = previewState {
        previewBody
      } else {
        patchFailureBody
      }
    }
  }

  @ViewBuilder private var patchFailureBody: some View {
    if case .failed(let message) = patchState {
      VStack(alignment: .leading, spacing: 6) {
        Text(message).font(errorFont).foregroundStyle(.orange)
      }
    }
  }

  @ViewBuilder private var previewBody: some View {
    switch previewState {
    case .notLoaded:
      ProgressView().controlSize(.small)
    case .loading:
      ProgressView().controlSize(.small)
    case .loaded(let preview):
      DashboardReviewFileDiffPreview(
        preview: preview,
        viewMode: viewMode,
        language: file.languageHint,
        fontScale: fontScale,
        softWrapEnabled: softWrapEnabled,
        threads: threads,
        repositoryFullName: repositoryFullName,
        isLoadingFullPatch: patchState == .loading,
        fullPatchFailed: patchState.isFailed
      )
    case .failed(let message):
      VStack(alignment: .leading, spacing: 6) {
        Text(message).font(errorFont).foregroundStyle(.orange)
      }
    }
  }

  private func loadPreviewIfNeeded() {
    switch previewState {
    case .notLoaded, .failed:
      onLoadPreview()
    case .loading, .loaded:
      break
    }
  }

  private func loadFullPatchIfPreviewFinished() {
    guard
      Self.shouldLoadFullPatch(
        previewState: previewState,
        patchState: patchState,
        isBinary: file.isBinary
      )
    else {
      return
    }
    onLoadPatch()
  }

  nonisolated static func shouldLoadFullPatch(
    previewState: ReviewFilePreviewState,
    patchState: ReviewFilePatchState,
    isBinary: Bool = false
  ) -> Bool {
    guard case .notLoaded = patchState else { return false }
    switch previewState {
    case .loaded(let preview):
      return preview.hasMore || isBinary
    case .failed:
      return true
    case .notLoaded, .loading:
      return false
    }
  }

}

extension ReviewFilePatchState {
  fileprivate var isFailed: Bool {
    switch self {
    case .failed:
      return true
    case .notLoaded, .loading, .loaded:
      return false
    }
  }
}
