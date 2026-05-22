import HarnessMonitorKit
import SwiftUI

/// Inline PR file-changes section inside the Dashboard Dependencies
/// detail pane. Resolves the per-PR view model from the store; the
/// detail view passes only the pullRequestID so changes to one PR's
/// files don't invalidate other detail panes mounted in tab groups.
struct DashboardDependencyFilesSection: View {
  let pullRequestID: String

  @Environment(HarnessMonitorStore.self) private var store
  @Environment(\.dependenciesPreferences) private var preferences
  @State private var filter = DashboardDependencyFilesFilterState()

  var body: some View {
    let viewModel = store.viewModel(forPullRequest: pullRequestID)
    return VStack(alignment: .leading, spacing: 12) {
      DashboardDependencyFilesHeader(viewModel: viewModel, filter: filter)
      contentBody(viewModel: viewModel)
    }
    .task(id: pullRequestID) {
      await store.prepareDependencyUpdateFiles(pullRequestID: pullRequestID)
    }
    .onAppear { syncFilterFromPreferences() }
    .onChange(of: filter.snapshotID) { _, _ in
      viewModel.applyFilter(filter.snapshot)
    }
    .accessibilityIdentifier("dashboardDependencyFilesSection")
  }

  @ViewBuilder
  private func contentBody(viewModel: DependencyUpdateFilesViewModel) -> some View {
    switch viewModel.state {
    case .idle, .loading:
      DashboardDependencyFilesEmptyState(reason: .loading)
    case .error(let message):
      DashboardDependencyFilesEmptyState(reason: .error(message: message))
    case .loaded:
      if viewModel.filteredFiles.isEmpty {
        DashboardDependencyFilesEmptyState(reason: viewModel.files.isEmpty ? .noFiles : .filteredOut)
      } else {
        filesList(viewModel: viewModel)
      }
    }
  }

  private func filesList(viewModel: DependencyUpdateFilesViewModel) -> some View {
    LazyVStack(alignment: .leading, spacing: 8) {
      ForEach(viewModel.filteredFiles, id: \.path) { file in
        DashboardDependencyFileCard(
          file: file,
          viewedState: viewModel.viewedByPath[file.path] ?? file.viewerViewedState,
          patchState: viewModel.patches[file.path] ?? .notLoaded,
          viewMode: viewModel.viewMode(forPath: file.path),
          onToggleViewed: { newValue in
            store.setFileViewed(
              pullRequestID: pullRequestID,
              path: file.path,
              viewed: newValue
            )
          },
          onChangeViewMode: { mode in
            viewModel.setViewMode(mode, forPath: file.path)
          },
          onLoadPatch: {
            Task {
              await store.preparePatches(
                forPullRequest: pullRequestID,
                paths: [file.path]
              )
            }
          }
        )
      }
    }
  }

  private func syncFilterFromPreferences() {
    let prefs = preferences.snapshot
    filter.hideGenerated = prefs.filesHideGenerated
    filter.hideWhitespaceOnly = prefs.filesHideWhitespaceOnly
    filter.generatedPathMatcher = preferences.compiledGeneratedPatternMatcher
  }
}

/// Empty / loading / error states for the Files section.
struct DashboardDependencyFilesEmptyState: View {
  enum Reason: Equatable {
    case loading
    case noFiles
    case filteredOut
    case error(message: String)
  }

  let reason: Reason

  var body: some View {
    VStack(alignment: .center, spacing: 6) {
      icon
      Text(title).font(.headline)
      if let subtitle {
        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.vertical, 20)
    .accessibilityIdentifier("dashboardDependencyFilesEmptyState")
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(title))
  }

  private var icon: some View {
    Group {
      switch reason {
      case .loading:
        ProgressView()
      case .noFiles:
        Image(systemName: "doc.text.magnifyingglass")
      case .filteredOut:
        Image(systemName: "line.3.horizontal.decrease.circle")
      case .error:
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      }
    }
  }

  private var title: String {
    switch reason {
    case .loading: return "Loading files…"
    case .noFiles: return "No files changed in this pull request"
    case .filteredOut: return "All files are hidden by the current filter"
    case .error: return "Failed to load files"
    }
  }

  private var subtitle: String? {
    if case .error(let message) = reason { return message }
    return nil
  }
}
