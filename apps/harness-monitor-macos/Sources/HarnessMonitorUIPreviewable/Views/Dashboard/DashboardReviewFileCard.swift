import HarnessMonitorKit
import SwiftUI

/// POD wrapper around `DashboardReviewFileCardInternal`. Holds only
/// plain value types so SwiftUI's diff can `memcmp`-compare across body
/// invocations.
struct DashboardReviewFileCard: View {
  let file: ReviewFile
  let viewedState: ReviewFileViewedState
  let previewState: ReviewFilePreviewState
  let patchState: ReviewFilePatchState
  let viewMode: FilesViewMode
  let pullRequestID: String
  let repositoryID: String
  let onToggleViewed: @MainActor (Bool) -> Void
  let onChangeViewMode: @MainActor (FilesViewMode) -> Void
  let onLoadPreview: @MainActor () -> Void
  let onLoadPatch: @MainActor () -> Void

  var body: some View {
    DashboardReviewFileCardInternal(
      file: file,
      viewedState: viewedState,
      previewState: previewState,
      patchState: patchState,
      viewMode: viewMode,
      pullRequestID: pullRequestID,
      repositoryID: repositoryID,
      onToggleViewed: onToggleViewed,
      onChangeViewMode: onChangeViewMode,
      onLoadPreview: onLoadPreview,
      onLoadPatch: onLoadPatch
    )
  }
}

struct DashboardReviewFileCardInternal: View {
  let file: ReviewFile
  let viewedState: ReviewFileViewedState
  let previewState: ReviewFilePreviewState
  let patchState: ReviewFilePatchState
  let viewMode: FilesViewMode
  let pullRequestID: String
  let repositoryID: String
  let onToggleViewed: @MainActor (Bool) -> Void
  let onChangeViewMode: @MainActor (FilesViewMode) -> Void
  let onLoadPreview: @MainActor () -> Void
  let onLoadPatch: @MainActor () -> Void

  @State private var isExpanded: Bool = false

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
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewFileCard(path: file.path))
  }

  private var header: some View {
    HStack(spacing: 12) {
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
            .font(.caption.weight(.semibold))
            .frame(width: 28, height: 28)
            .contentShape(.rect)
        }
      )
      .harnessPlainButtonStyle()
      .help(isExpanded ? "Collapse file diff" : "Expand file diff")
      .accessibilityLabel(isExpanded ? "Collapse \(file.path)" : "Expand \(file.path)")

      pathLabel
      Spacer(minLength: 0)
      changeCounts

      Toggle(
        "Viewed",
        isOn: Binding(
          get: { viewedState == .viewed },
          set: { onToggleViewed($0) }
        )
      )
      .toggleStyle(.checkbox)
      .controlSize(.small)
      .help(viewedState == .viewed ? "Mark file unviewed" : "Mark file viewed")
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.dashboardReviewFileViewedToggle(path: file.path)
      )

      Menu {
        Button(
          action: { onChangeViewMode(.unified) },
          label: {
            Label("Unified", systemImage: viewMode == .unified ? "checkmark" : "")
          }
        )
        Button(
          action: { onChangeViewMode(.split) },
          label: {
            Label("Split", systemImage: viewMode == .split ? "checkmark" : "")
          }
        )
      } label: {
        Label(viewMode.label, systemImage: "rectangle.split.2x1")
      }
      .help("Change diff view")
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.dashboardReviewFileViewModeMenu(path: file.path)
      )
    }
    .frame(minHeight: 32)
  }

  private var pathLabel: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(file.path)
        .font(.body.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .layoutPriority(1)
      if let previousPath = file.previousPath, previousPath != file.path {
        Label("renamed from \(previousPath)", systemImage: "arrow.right")
          .labelStyle(.titleAndIcon)
          .font(.caption2)
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
        Text("+\(file.additions)").foregroundStyle(.green).font(.caption.monospacedDigit())
      }
      if file.deletions > 0 {
        Text("-\(file.deletions)").foregroundStyle(.red).font(.caption.monospacedDigit())
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
          repositoryID: repositoryID
        )
      } else if viewMode == .split {
        DashboardReviewFileDiffSplit(patch: patch, language: file.languageHint)
      } else {
        DashboardReviewFileDiffUnified(patch: patch, language: file.languageHint)
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
        Text(message).font(.caption).foregroundStyle(.orange)
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
      DashboardReviewFileDiffPreview(preview: preview)
      if case .loading = patchState {
        ProgressView().controlSize(.small)
      }
    case .failed(let message):
      VStack(alignment: .leading, spacing: 6) {
        Text(message).font(.caption).foregroundStyle(.orange)
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
    switch previewState {
    case .loaded, .failed:
      guard case .notLoaded = patchState else { return }
      onLoadPatch()
    case .notLoaded, .loading:
      break
    }
  }

  private var accessibilityLabel: Text {
    Text(
      """
      File \(file.path), \(file.additions) additions, \(file.deletions) deletions, \
      \(viewedState == .viewed ? "viewed" : "not viewed")
      """
    )
  }
}

extension FilesViewMode {
  fileprivate var label: String {
    switch self {
    case .unified:
      "Unified"
    case .split:
      "Split"
    }
  }
}
