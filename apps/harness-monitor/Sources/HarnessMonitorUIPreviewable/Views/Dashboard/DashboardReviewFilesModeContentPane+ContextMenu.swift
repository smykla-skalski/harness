import HarnessMonitorKit
import SwiftUI

extension DashboardReviewFilesModeContentPane {
  @ViewBuilder
  func fileSelectionContextMenu(
    for selection: Set<String>,
    presentation: DashboardReviewFilesModePresentation,
    viewModel: ReviewFilesViewModel,
    visiblePaths: [String]
  ) -> some View {
    let items = contextMenuItems(
      for: selection,
      presentation: presentation,
      viewModel: viewModel
    )
    let _: Task<Void, Never> = Task { @MainActor in
      _ = primeSelectionForContextMenu(
        paths: selection,
        visiblePaths: visiblePaths,
        viewModel: viewModel
      )
    }
    if !items.isEmpty {
      let harnessURLs = items.compactMap(\.harnessURL)
      let blobURLs = items.compactMap(\.blobURL)
      let pullRequestFileURLs = items.compactMap(\.pullRequestFileURL)
      Button(dashboardReviewCopyFilenamesMenuTitle(itemCount: items.count)) {
        HarnessMonitorClipboard.copy(items.map(\.fileName).joined(separator: "\n"))
      }
      Button(dashboardReviewCopyPathsMenuTitle(itemCount: items.count)) {
        HarnessMonitorClipboard.copy(items.map(\.file.path).joined(separator: "\n"))
      }
      if !harnessURLs.isEmpty || !blobURLs.isEmpty || !pullRequestFileURLs.isEmpty {
        Divider()
      }
      if !harnessURLs.isEmpty {
        Button(dashboardReviewCopyHarnessLinksMenuTitle(itemCount: harnessURLs.count)) {
          HarnessMonitorClipboard.copy(harnessURLs.map(\.absoluteString).joined(separator: "\n"))
        }
      }
      if !blobURLs.isEmpty {
        Button(dashboardReviewCopyGitHubLinksMenuTitle(itemCount: blobURLs.count)) {
          HarnessMonitorClipboard.copy(blobURLs.map(\.absoluteString).joined(separator: "\n"))
        }
        Button(dashboardReviewOpenGitHubLinksMenuTitle(itemCount: blobURLs.count)) {
          openGitHubURLs(blobURLs)
        }
      }
      if !pullRequestFileURLs.isEmpty {
        Button(
          dashboardReviewCopyPullRequestFileLinksMenuTitle(itemCount: pullRequestFileURLs.count)
        ) {
          HarnessMonitorClipboard.copy(
            pullRequestFileURLs.map(\.absoluteString).joined(separator: "\n")
          )
        }
      }
    }
  }

  func contextMenuItems(
    for selection: Set<String>,
    presentation: DashboardReviewFilesModePresentation,
    viewModel: ReviewFilesViewModel
  ) -> [DashboardReviewFilesContextMenuItem] {
    guard !selection.isEmpty else { return [] }
    var items: [DashboardReviewFilesContextMenuItem] = []
    items.reserveCapacity(selection.count)
    for file in presentation.visibleFiles where selection.contains(file.path) {
      items.append(
        DashboardReviewFilesContextMenuItem(
          file: file,
          harnessURL: dashboardReviewFileHarnessURL(
            deepLinkID: item.pullRequestDeepLinkID ?? "",
            path: file.path
          ),
          blobURL: dashboardReviewFileBlobURL(
            repositoryFullName: viewModel.repositoryFullName,
            headRefOid: viewModel.headRefOid,
            path: file.path
          ),
          pullRequestFileURL: dashboardReviewPullRequestFileURL(
            repositoryFullName: viewModel.repositoryFullName,
            pullRequestNumber: viewModel.number ?? item.number,
            path: file.path
          )
        )
      )
    }
    return items
  }

  @discardableResult
  func primeSelectionForContextMenu(
    paths: Set<String>,
    visiblePaths: [String],
    viewModel: ReviewFilesViewModel
  ) -> Bool {
    guard !paths.isEmpty else { return false }
    let displayed = displayedStoredListSelection(fallbackPrimaryPath: viewModel.selectedPath)
    guard displayed != paths else { return false }
    let primaryPath = applyStoredListSelection(
      paths,
      fallbackPrimaryPath: viewModel.selectedPath,
      orderedVisiblePaths: visiblePaths
    )
    syncPrimarySelection(primaryPath, viewModel: viewModel)
    syncListSelection(visiblePaths: visiblePaths, primaryPath: viewModel.selectedPath)
    return true
  }

  func openGitHubURLs(_ urls: [URL]) {
    for url in urls {
      openURL(url)
    }
  }
}
