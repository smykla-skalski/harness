import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  var routeDetailMode: DashboardReviewsDetailMode {
    get { DashboardReviewsDetailMode(rawValue: detailModeRaw) ?? .overview }
    nonmutating set { detailModeRaw = newValue.rawValue }
  }

  var routeFileSelections: DashboardReviewsFileSelectionStorage {
    get { DashboardReviewsFileSelectionStorage.decode(fileSelectionsRaw) }
    nonmutating set { fileSelectionsRaw = newValue.encoded() }
  }

  func enterFilesMode(for item: ReviewItem) {
    let interval = ReviewFilesPerf.beginFilesModeEnter(pullRequestID: item.pullRequestID)
    routeSelectedIDs = [item.pullRequestID]
    persistedPrimarySelectionID = item.pullRequestID
    routeDetailMode = .files
    Task {
      defer { ReviewFilesPerf.end(interval) }
      await prepareFilesMode(for: item)
    }
  }

  func exitFilesMode() {
    routeDetailMode = .overview
  }

  func restoreSelectedFile(
    for pullRequestID: String,
    viewModel: ReviewFilesViewModel
  ) {
    if let path = routeFileSelections.rememberedPath(for: pullRequestID) {
      viewModel.select(path: path)
    }
    viewModel.ensureSelectedPath()
  }

  func rememberSelectedFile(_ path: String?, for pullRequestID: String) {
    var selections = routeFileSelections
    selections.remember(path: path, for: pullRequestID)
    routeFileSelections = selections
  }

  @MainActor
  func prepareFilesMode(for item: ReviewItem) async {
    let viewModel = store.viewModel(forPullRequest: item.pullRequestID)
    restoreSelectedFile(for: item.pullRequestID, viewModel: viewModel)
    await store.prepareReviewFiles(pullRequestID: item.pullRequestID)
    await store.prepareReviewTimeline(for: item)
    viewModel.ensureSelectedPath()
    rememberSelectedFile(viewModel.selectedPath, for: item.pullRequestID)
  }

  func filesModeContentPane(for item: ReviewItem) -> some View {
    let viewModel = store.viewModel(forPullRequest: item.pullRequestID)
    return DashboardReviewFilesModeContentPane(
      item: item,
      viewModel: viewModel,
      store: store,
      onBack: exitFilesMode,
      onSelectPath: { path in
        viewModel.select(path: path)
        rememberSelectedFile(path, for: item.pullRequestID)
      }
    )
    .id("files-content-\(item.pullRequestID)")
  }

  func filesModeDetailPane(for item: ReviewItem) -> some View {
    let viewModel = store.viewModel(forPullRequest: item.pullRequestID)
    return DashboardReviewFilesModeDetailPane(
      item: item,
      viewModel: viewModel,
      store: store,
      viewerLogin: routeResponse.viewerLogin,
      onBack: exitFilesMode,
      onSelectPath: { path in
        viewModel.select(path: path)
        rememberSelectedFile(path, for: item.pullRequestID)
      }
    )
    .id("files-detail-\(item.pullRequestID)")
  }
}
