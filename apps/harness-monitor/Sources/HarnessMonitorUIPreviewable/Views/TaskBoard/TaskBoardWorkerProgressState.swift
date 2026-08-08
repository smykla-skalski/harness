import HarnessMonitorKit
import Observation
import SwiftUI

@MainActor
@Observable
final class TaskBoardWorkerProgressState {
  enum LoadState {
    case idle
    case loading
    /// Carries the resolved presentation, not the raw response: timestamps are
    /// parsed once here so no view body ever parses one.
    case loaded(TaskBoardWorkerProgressPresentation?)
    case failed
  }

  private(set) var loadState: LoadState = .idle
  @ObservationIgnored private var itemID: String?
  @ObservationIgnored private var token = 0

  init(response: TaskBoardWorkItemProgressResponse? = nil) {
    loadState = response.map { .loaded(Self.presentation(for: $0)) } ?? .idle
  }

  var presentation: TaskBoardWorkerProgressPresentation? {
    guard case .loaded(let presentation) = loadState else { return nil }
    return presentation
  }

  var progress: TaskBoardWorkItemProgress? {
    presentation?.progress
  }

  var isLoading: Bool {
    if case .loading = loadState { return true }
    return false
  }

  var didFail: Bool {
    if case .failed = loadState { return true }
    return false
  }

  /// True once a load finished and the item turned out never to have been
  /// dispatched, which is a different thing to show than "still loading".
  var isUndispatched: Bool {
    guard case .loaded(let presentation) = loadState else { return false }
    return presentation == nil
  }

  func load(item: TaskBoardItem, actions: TaskBoardOverviewActions) async {
    await load(item: item, store: actions.store)
  }

  func load(item: TaskBoardItem, store: HarnessMonitorStore?) async {
    itemID = item.id
    token += 1
    let loadToken = token
    loadState = .loading
    let response = await store?.taskBoardItemProgress(id: item.id)
    guard itemID == item.id, token == loadToken else { return }
    guard !Task.isCancelled else {
      loadState = .idle
      return
    }
    loadState = response.map { .loaded(Self.presentation(for: $0)) } ?? .failed
  }

  private static func presentation(
    for response: TaskBoardWorkItemProgressResponse
  ) -> TaskBoardWorkerProgressPresentation? {
    response.progress.map(TaskBoardWorkerProgressPresentation.init(progress:))
  }
}
