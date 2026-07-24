import HarnessMonitorKit
import SwiftUI

/// Fetched once per item selection via `.task(id:)`; `receive(_:)` is the
/// only path a mutation uses to refresh it. Loads and mutation refreshes
/// are fenced by item id + a monotonic token so a stale in-flight response
/// can never overwrite a newer selection.
@MainActor
@Observable
final class TaskBoardTriageInspectorState {
  /// `.loaded(nil current)` is a genuine empty response; `.failed` means
  /// the read itself didn't come back. Never conflate the two.
  enum LoadState {
    case idle
    case loading
    case loaded(TaskBoardTriageCurrentResponse)
    case failed
  }

  private(set) var loadState: LoadState = .idle
  var overrideReasonDraft = "" {
    didSet {
      guard !isSeedingOverrideReason else { return }
      isOverrideReasonDraftDirty = overrideReasonDraft != seededOverrideReason
    }
  }
  private var itemID: String?
  private var token = 0
  private var historyToken = 0
  private var seededOverrideReason = ""
  private var isSeedingOverrideReason = false
  private var mutationInFlight = false
  private var suppressedLoadUpdatedAt: String?
  private(set) var isOverrideReasonDraftDirty = false
  private(set) var historyDecisions: [TaskBoardTriageDecisionRecord] = []
  private(set) var historyNextBeforeGeneration: UInt64?
  private(set) var historyWasRequested = false
  private(set) var isHistoryLoading = false
  private(set) var didHistoryFail = false
  private(set) var historyReachedDisplayLimit = false
  private static let historyPageLimit: UInt32 = 20
  private static let historyDisplayLimit = 100

  var current: TaskBoardTriageCurrentResponse? {
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

  /// True once a read has come back, even a valid empty one -- distinct
  /// from `.idle` before the first `.task(id:)` fires.
  var hasLoadedResponse: Bool {
    if case .loaded = loadState { return true }
    return false
  }

  func load(item: TaskBoardItem, actions: TaskBoardOverviewActions) async {
    await load(item: item, store: actions.store)
  }

  func load(item: TaskBoardItem, store: HarnessMonitorStore?) async {
    let itemChanged = itemID != item.id
    if !itemChanged, mutationInFlight {
      return
    }
    if !itemChanged, suppressedLoadUpdatedAt == item.updatedAt {
      suppressedLoadUpdatedAt = nil
      return
    }
    if itemChanged {
      seedOverrideReason("")
      mutationInFlight = false
      suppressedLoadUpdatedAt = nil
    }
    resetHistory()
    itemID = item.id
    token += 1
    let loadToken = token
    loadState = .loading
    let response = await store?.taskBoardItemTriageCurrent(id: item.id)
    guard itemID == item.id, token == loadToken else { return }
    loadState = response.map(LoadState.loaded) ?? .failed
    if let response {
      // itemChanged already ran synchronously above; this must not
      // re-clobber a draft typed during the load.
      adoptOverrideReason(from: response, itemChanged: false)
    }
  }

  /// Captured before a mutation's async work starts, for `receive` to fence
  /// its eventual refresh against.
  func currentToken() -> Int {
    token
  }

  func beginMutation(itemID: String) -> Int {
    guard self.itemID == itemID else { return token }
    token += 1
    mutationInFlight = true
    resetHistory()
    return token
  }

  func receive(
    _ response: TaskBoardTriageCurrentResponse?,
    itemID: String,
    itemUpdatedAt: String? = nil,
    token: Int
  ) {
    guard self.itemID == itemID, self.token == token else { return }
    mutationInFlight = false
    suppressedLoadUpdatedAt = itemUpdatedAt
    loadState = response.map(LoadState.loaded) ?? .failed
    if let response {
      adoptOverrideReason(from: response, itemChanged: false)
    }
  }

  func loadHistory(
    item: TaskBoardItem,
    actions: TaskBoardOverviewActions,
    reset: Bool
  ) async {
    await loadHistory(item: item, store: actions.store, reset: reset)
  }

  func loadHistory(
    item: TaskBoardItem,
    store: HarnessMonitorStore?,
    reset: Bool
  ) async {
    guard itemID == item.id, !isHistoryLoading else { return }
    let beforeGeneration = reset ? nil : historyNextBeforeGeneration
    if !reset, beforeGeneration == nil, historyWasRequested {
      return
    }
    historyToken += 1
    let loadToken = historyToken
    historyWasRequested = true
    isHistoryLoading = true
    didHistoryFail = false
    let response = await store?.taskBoardItemTriageHistory(
      id: item.id,
      beforeGeneration: beforeGeneration,
      limit: Self.historyPageLimit
    )
    guard itemID == item.id, historyToken == loadToken else { return }
    isHistoryLoading = false
    guard let response else {
      didHistoryFail = true
      return
    }
    let combined =
      reset ? response.decisions : Self.appendingUnique(response.decisions, to: historyDecisions)
    historyReachedDisplayLimit =
      combined.count > Self.historyDisplayLimit
      || (combined.count == Self.historyDisplayLimit && response.nextBeforeGeneration != nil)
    historyDecisions = Array(combined.prefix(Self.historyDisplayLimit))
    historyNextBeforeGeneration =
      historyReachedDisplayLimit ? nil : response.nextBeforeGeneration
  }

  private func adoptOverrideReason(
    from response: TaskBoardTriageCurrentResponse,
    itemChanged: Bool
  ) {
    let reason =
      if let triageOverride = response.triageOverride,
        triageOverride.actor != SupervisorAuditSensitiveKeys.redactionPlaceholder
      {
        triageOverride.reason ?? ""
      } else {
        ""
      }
    if itemChanged || !isOverrideReasonDraftDirty || overrideReasonDraft == reason {
      seedOverrideReason(reason)
    }
  }

  private func seedOverrideReason(_ reason: String) {
    seededOverrideReason = reason
    isSeedingOverrideReason = true
    overrideReasonDraft = reason
    isSeedingOverrideReason = false
    isOverrideReasonDraftDirty = false
  }

  private func resetHistory() {
    historyToken += 1
    historyDecisions = []
    historyNextBeforeGeneration = nil
    historyWasRequested = false
    isHistoryLoading = false
    didHistoryFail = false
    historyReachedDisplayLimit = false
  }

  private static func appendingUnique(
    _ decisions: [TaskBoardTriageDecisionRecord],
    to existing: [TaskBoardTriageDecisionRecord]
  ) -> [TaskBoardTriageDecisionRecord] {
    let existingIDs = Set(existing.map(\.decisionId))
    return existing + decisions.filter { !existingIDs.contains($0.decisionId) }
  }
}
