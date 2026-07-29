import HarnessMonitorKit
import SwiftUI

@MainActor
@Observable
final class TaskBoardReviewReportState {
  enum LoadState {
    case idle
    case loading
    case loaded(TaskBoardAiReviewReportResponse)
    case failed
  }

  private(set) var loadState: LoadState = .idle
  private var itemID: String?
  private var token = 0

  init(response: TaskBoardAiReviewReportResponse? = nil) {
    loadState = response.map(LoadState.loaded) ?? .idle
  }

  var response: TaskBoardAiReviewReportResponse? {
    guard case .loaded(let response) = loadState else { return nil }
    return response
  }

  var isLoading: Bool {
    if case .loading = loadState { return true }
    return false
  }

  var didFail: Bool {
    if case .failed = loadState { return true }
    return false
  }

  func load(item: TaskBoardItem, actions: TaskBoardOverviewActions) async {
    await load(item: item, store: actions.store)
  }

  func load(item: TaskBoardItem, store: HarnessMonitorStore?) async {
    itemID = item.id
    token += 1
    let loadToken = token
    loadState = .loading
    let response = await store?.taskBoardItemReviewReport(id: item.id)
    guard itemID == item.id, token == loadToken else { return }
    guard !Task.isCancelled else {
      loadState = .idle
      return
    }
    loadState = response.map(LoadState.loaded) ?? .failed
  }
}
