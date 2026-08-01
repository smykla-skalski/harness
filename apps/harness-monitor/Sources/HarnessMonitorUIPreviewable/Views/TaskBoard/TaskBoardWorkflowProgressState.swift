import HarnessMonitorKit
import Observation
import SwiftUI

@MainActor
@Observable
final class TaskBoardWorkflowProgressState {
  enum LoadState {
    case idle
    case loading
    case loaded(TaskBoardWorkflowProgressResponse)
    case failed
  }

  private(set) var loadState: LoadState = .idle
  @ObservationIgnored private var itemID: String?
  @ObservationIgnored private var token = 0

  init(response: TaskBoardWorkflowProgressResponse? = nil) {
    loadState = response.map(LoadState.loaded) ?? .idle
  }

  var progress: TaskBoardWorkflowProgress? {
    guard case .loaded(let response) = loadState else { return nil }
    return response.progress
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
    let response = await store?.taskBoardItemWorkflowProgress(id: item.id)
    guard itemID == item.id, token == loadToken else { return }
    guard !Task.isCancelled else {
      loadState = .idle
      return
    }
    loadState = response.map(LoadState.loaded) ?? .failed
  }
}
