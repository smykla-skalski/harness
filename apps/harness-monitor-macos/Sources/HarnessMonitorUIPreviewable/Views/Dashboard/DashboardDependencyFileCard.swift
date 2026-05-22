import HarnessMonitorKit
import SwiftUI

/// POD wrapper around `DashboardDependencyFileCardInternal`. Holds only
/// plain value types so SwiftUI's diff can `memcmp`-compare across body
/// invocations.
struct DashboardDependencyFileCard: View {
  let file: DependencyUpdateFile
  let viewedState: DependencyUpdateFileViewedState
  let patchState: DependencyUpdateFilePatchState
  let viewMode: FilesViewMode
  let onToggleViewed: @MainActor (Bool) -> Void
  let onChangeViewMode: @MainActor (FilesViewMode) -> Void
  let onLoadPatch: @MainActor () -> Void

  var body: some View {
    DashboardDependencyFileCardInternal(
      file: file,
      viewedState: viewedState,
      patchState: patchState,
      viewMode: viewMode,
      onToggleViewed: onToggleViewed,
      onChangeViewMode: onChangeViewMode,
      onLoadPatch: onLoadPatch
    )
  }
}

struct DashboardDependencyFileCardInternal: View {
  let file: DependencyUpdateFile
  let viewedState: DependencyUpdateFileViewedState
  let patchState: DependencyUpdateFilePatchState
  let viewMode: FilesViewMode
  let onToggleViewed: @MainActor (Bool) -> Void
  let onChangeViewMode: @MainActor (FilesViewMode) -> Void
  let onLoadPatch: @MainActor () -> Void

  @State private var isExpanded: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if isExpanded {
        patchBody
      }
    }
    .padding(12)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier("dashboardDependencyFileCard(\(file.path))")
  }

  private var header: some View {
    HStack(spacing: 8) {
      Button(action: { isExpanded.toggle() }) {
        HStack(spacing: 6) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .frame(width: 12)
          pathLabel
          Spacer(minLength: 0)
          changeCounts
        }
      }
      .buttonStyle(.plain)

      Toggle("", isOn: Binding(
        get: { viewedState == .viewed },
        set: { onToggleViewed($0) }
      ))
      .labelsHidden()
      .toggleStyle(.checkbox)
      .accessibilityIdentifier("dashboardDependencyFileViewedToggle(\(file.path))")

      Menu {
        Button(action: { onChangeViewMode(.unified) }) {
          Label("Unified", systemImage: viewMode == .unified ? "checkmark" : "")
        }
        Button(action: { onChangeViewMode(.split) }) {
          Label("Split", systemImage: viewMode == .split ? "checkmark" : "")
        }
      } label: {
        Image(systemName: "rectangle.split.2x1")
      }
      .accessibilityIdentifier("dashboardDependencyFileViewModeMenu(\(file.path))")
    }
  }

  private var pathLabel: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(file.path)
        .font(.body.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
      if let previousPath = file.previousPath, previousPath != file.path {
        Text("renamed from \(previousPath)")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
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
  }

  @ViewBuilder
  private var patchBody: some View {
    switch patchState {
    case .notLoaded:
      Button("Load patch") { onLoadPatch() }
        .accessibilityIdentifier("dashboardDependencyFileLoadPatch(\(file.path))")
    case .loading:
      ProgressView().controlSize(.small)
    case .loaded(let patch):
      if file.isBinary {
        DashboardDependencyFileImagePreview(file: file, patch: patch)
      } else if viewMode == .split {
        DashboardDependencyFileDiffSplit(patch: patch, language: file.languageHint)
      } else {
        DashboardDependencyFileDiffUnified(patch: patch, language: file.languageHint)
      }
    case .failed(let message):
      Text(message).font(.caption).foregroundStyle(.orange)
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
