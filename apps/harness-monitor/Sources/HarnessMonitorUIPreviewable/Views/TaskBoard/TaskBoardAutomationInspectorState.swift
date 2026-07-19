import HarnessMonitorKit
import Observation

enum TaskBoardAutomationInspectorSurface: String, CaseIterable, Identifiable, Hashable {
  case automation
  case manual
  case history

  static let stableAllCases = Self.allCases

  var id: String { rawValue }

  var title: String {
    rawValue.capitalized
  }
}

enum TaskBoardAutomationInspectorAction: String, Equatable, Sendable {
  case start
  case stop
  case runOnce
}

enum TaskBoardAutomationHistoryLoad: Equatable {
  case idle
  case initial
  case older
}

struct TaskBoardAutomationHistoryLoadRequest: Sendable {
  let generation: UInt64
  let before: String?
  let replacesRuns: Bool
}

struct TaskBoardAutomationDetailLoadRequest: Sendable {
  let generation: UInt64
  let runID: String
}

struct TaskBoardAutomationMetricsLoadRequest: Sendable {
  let generation: UInt64
}

struct TaskBoardAutomationActionRequest: Sendable {
  let generation: UInt64
  let action: TaskBoardAutomationInspectorAction
}

@MainActor
@Observable
final class TaskBoardAutomationInspectorState {
  var surface = TaskBoardAutomationInspectorSurface.automation
  var activeAction: TaskBoardAutomationInspectorAction?
  var historyLoad = TaskBoardAutomationHistoryLoad.idle
  var isMetricsLoading = false
  var isDetailLoading = false
  var runs: [TaskBoardAutomationRunInfo] = []
  var nextCursor: String?
  var hasOlder = false
  var selectedRunID: String?
  var detail: TaskBoardAutomationRunDetail?
  var metrics: TaskBoardAutomationMetrics?
  private(set) var presentationRevision: UInt64 = 0
  private var historyGeneration: UInt64 = 0
  private var detailGeneration: UInt64 = 0
  private var metricsGeneration: UInt64 = 0
  private var actionGeneration: UInt64 = 0

  func beginInitialHistoryLoad(force: Bool) -> TaskBoardAutomationHistoryLoadRequest? {
    guard historyLoad == .idle, force || runs.isEmpty else { return nil }
    historyGeneration &+= 1
    historyLoad = .initial
    return TaskBoardAutomationHistoryLoadRequest(
      generation: historyGeneration,
      before: nil,
      replacesRuns: true
    )
  }

  func beginOlderHistoryLoad() -> TaskBoardAutomationHistoryLoadRequest? {
    guard historyLoad == .idle, hasOlder, let nextCursor else { return nil }
    historyGeneration &+= 1
    historyLoad = .older
    return TaskBoardAutomationHistoryLoadRequest(
      generation: historyGeneration,
      before: nextCursor,
      replacesRuns: false
    )
  }

  func completeHistory(
    request: TaskBoardAutomationHistoryLoadRequest,
    response: TaskBoardAutomationHistoryResponse?
  ) {
    guard request.generation == historyGeneration else { return }
    defer { historyLoad = .idle }
    guard let response else { return }

    if request.replacesRuns {
      runs = Self.uniqueRuns(response.runs)
      if let selectedRunID, !runs.contains(where: { $0.runId == selectedRunID }) {
        detailGeneration &+= 1
        self.selectedRunID = nil
        detail = nil
        isDetailLoading = false
      }
    } else {
      var knownRunIDs = Set(runs.map(\.runId))
      runs.append(contentsOf: response.runs.filter { knownRunIDs.insert($0.runId).inserted })
    }
    nextCursor = response.nextCursor
    hasOlder =
      response.hasOlder
      && response.nextCursor != nil
      && response.nextCursor != request.before
    presentationRevision &+= 1
  }

  func beginDetailLoad(runID: String) -> TaskBoardAutomationDetailLoadRequest? {
    guard selectedRunID != runID || !isDetailLoading else { return nil }
    detailGeneration &+= 1
    selectedRunID = runID
    detail = nil
    isDetailLoading = true
    presentationRevision &+= 1
    return TaskBoardAutomationDetailLoadRequest(
      generation: detailGeneration,
      runID: runID
    )
  }

  func completeDetail(
    request: TaskBoardAutomationDetailLoadRequest,
    detail: TaskBoardAutomationRunDetail?
  ) {
    guard request.generation == detailGeneration, selectedRunID == request.runID else {
      return
    }
    self.detail = detail
    isDetailLoading = false
    presentationRevision &+= 1
  }

  func beginMetricsLoad(force: Bool) -> TaskBoardAutomationMetricsLoadRequest? {
    guard !isMetricsLoading, force || metrics == nil else { return nil }
    metricsGeneration &+= 1
    isMetricsLoading = true
    return TaskBoardAutomationMetricsLoadRequest(generation: metricsGeneration)
  }

  func completeMetrics(
    request: TaskBoardAutomationMetricsLoadRequest,
    metrics: TaskBoardAutomationMetrics?
  ) {
    guard request.generation == metricsGeneration else { return }
    self.metrics = metrics ?? self.metrics
    isMetricsLoading = false
    if metrics != nil {
      presentationRevision &+= 1
    }
  }

  func resetRemoteData() {
    historyGeneration &+= 1
    detailGeneration &+= 1
    metricsGeneration &+= 1
    actionGeneration &+= 1
    historyLoad = .idle
    isMetricsLoading = false
    isDetailLoading = false
    runs = []
    nextCursor = nil
    hasOlder = false
    selectedRunID = nil
    detail = nil
    metrics = nil
    activeAction = nil
    presentationRevision &+= 1
  }

  func beginAction(
    _ action: TaskBoardAutomationInspectorAction
  ) -> TaskBoardAutomationActionRequest? {
    guard activeAction == nil else { return nil }
    actionGeneration &+= 1
    activeAction = action
    return TaskBoardAutomationActionRequest(generation: actionGeneration, action: action)
  }

  func completeAction(_ request: TaskBoardAutomationActionRequest) -> Bool {
    guard isCurrentAction(request) else { return false }
    activeAction = nil
    return true
  }

  func isCurrentAction(_ request: TaskBoardAutomationActionRequest) -> Bool {
    request.generation == actionGeneration && activeAction == request.action
  }

  private static func uniqueRuns(
    _ runs: [TaskBoardAutomationRunInfo]
  ) -> [TaskBoardAutomationRunInfo] {
    var seen: Set<String> = []
    return runs.filter { seen.insert($0.runId).inserted }
  }
}
