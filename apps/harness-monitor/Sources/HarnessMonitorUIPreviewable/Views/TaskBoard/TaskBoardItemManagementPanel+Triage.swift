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
        triageOverride.actor != "[redacted]"
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

struct TaskBoardManagementTriageSection: View {
  let item: TaskBoardItem
  let metrics: TaskBoardOverviewMetrics
  let isActionInFlight: Bool
  let actions: TaskBoardOverviewActions
  @Bindable var inspector: TaskBoardTriageInspectorState
  @Environment(\.fontScale)
  private var fontScale

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Triage")
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      automaticConclusionRow
      effectiveOutcomeRow
      overrideControlsOrExplanation
      historySection
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.manage-item.triage")
  }

  /// Mutation controls wait for a genuinely loaded read, else a user could
  /// unknowingly replace an override that just hasn't loaded yet.
  @ViewBuilder private var overrideControlsOrExplanation: some View {
    if let override = inspector.current?.triageOverride {
      overrideDetail(override)
      if actions.canMutateTaskBoardTriageOverride {
        if item.isTriageOverrideEligible {
          setOverrideControls
        }
        clearOverrideButton
      } else {
        readOnlyExplanation
      }
    } else if !item.isTriageOverrideEligible {
      ineligibleExplanation
    } else if inspector.hasLoadedResponse {
      if actions.canMutateTaskBoardTriageOverride {
        setOverrideControls
      } else {
        readOnlyExplanation
      }
    }
  }

  @ViewBuilder private var automaticConclusionRow: some View {
    if let decision = inspector.current?.current {
      Text(Self.automaticConclusionText(for: decision))
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .textSelection(.enabled)
        .accessibilityIdentifier("harness.task-board.manage-item.triage.automatic")
    } else if inspector.isLoading {
      Text("Loading triage…")
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityIdentifier("harness.task-board.manage-item.triage.loading")
    } else if inspector.didFail {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Text("Triage unavailable — could not reach the daemon")
          .font(captionFont)
          .foregroundStyle(HarnessMonitorTheme.caution)
        Button("Retry") {
          reloadCurrentTriage()
        }
        .font(captionFont)
      }
      .accessibilityIdentifier("harness.task-board.manage-item.triage.failed")
    } else if inspector.hasLoadedResponse {
      Text("Automatic: not yet evaluated")
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityIdentifier("harness.task-board.manage-item.triage.not-evaluated")
    }
  }

  private static func automaticConclusionText(for decision: TaskBoardTriageDecisionRecord)
    -> String
  {
    let base = "Automatic: \(decision.verdict.title) (\(decision.reasonCode.title))"
    guard let detail = decision.reasonDetail, !detail.isEmpty else { return base }
    return "\(base): \(detail)"
  }

  @ViewBuilder private var effectiveOutcomeRow: some View {
    if let effective = inspector.current?.effective {
      Text("Effective: \(effective.verdict.title) (\(effective.source.title))")
        .font(captionSemibold)
        .textSelection(.enabled)
        .accessibilityIdentifier("harness.task-board.manage-item.triage.effective")
    }
  }

  private func overrideDetail(_ override: TaskBoardTriageOverride) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Overridden by \(override.actor) at \(override.setAt)")
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .textSelection(.enabled)
      if let reason = override.reason, !reason.isEmpty {
        Text("Reason: \(reason)")
          .font(captionFont)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .textSelection(.enabled)
      }
    }
    .accessibilityIdentifier("harness.task-board.manage-item.triage.override-detail")
  }

  private var clearOverrideButton: some View {
    Button {
      actions.clearTaskBoardTriageOverride(item, refreshing: inspector)
    } label: {
      Label("Clear Override", systemImage: "arrow.uturn.backward")
        .font(captionSemibold)
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.caution)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight)
    .help("Clear the triage override and return this item to automatic handling")
    .accessibilityIdentifier("harness.task-board.manage-item.triage.clear-override")
  }

  private static let ineligibleExplanationText =
    "Triage override is not available for this item "
    + "(only a live Task in Backlog or Todo, with no linked work item, can be overridden)"

  private var ineligibleExplanation: some View {
    Text(Self.ineligibleExplanationText)
      .font(captionFont)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .accessibilityIdentifier("harness.task-board.manage-item.triage.ineligible")
  }

  private var readOnlyExplanation: some View {
    Text("Remote viewer access is read-only")
      .font(captionFont)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .accessibilityIdentifier("harness.task-board.manage-item.triage.read-only")
  }

  private var setOverrideControls: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      TaskBoardManagementNativeField(label: "Override reason", text: $inspector.overrideReasonDraft)
        .accessibilityIdentifier("harness.task-board.manage-item.triage.override-reason")
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Button {
          setOverride(verdict: .todo)
        } label: {
          Label("Set Todo", systemImage: "checkmark.circle")
            .font(captionSemibold)
        }
        .frame(minHeight: metrics.controlMinHeight)
        .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .disabled(isActionInFlight)
        .help("Override triage: move this item to Todo")
        .accessibilityIdentifier("harness.task-board.manage-item.triage.set-todo")

        Button {
          setOverride(verdict: .undecided)
        } label: {
          Label("Set Undecided", systemImage: "questionmark.circle")
            .font(captionSemibold)
        }
        .frame(minHeight: metrics.controlMinHeight)
        .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.caution)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .disabled(isActionInFlight)
        .help("Override triage: leave this item Undecided in Backlog")
        .accessibilityIdentifier("harness.task-board.manage-item.triage.set-undecided")
      }
    }
  }

  private func setOverride(verdict: TriageVerdict) {
    let trimmedReason = inspector.overrideReasonDraft.trimmingCharacters(
      in: .whitespacesAndNewlines)
    actions.setTaskBoardTriageOverride(
      item,
      verdict: verdict,
      reason: trimmedReason.isEmpty ? nil : trimmedReason,
      refreshing: inspector
    )
  }

  @ViewBuilder private var historySection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      if !inspector.historyWasRequested {
        Button("Show History") {
          loadHistory(reset: true)
        }
        .font(captionFont)
        .accessibilityIdentifier("harness.task-board.manage-item.triage.history.show")
      } else {
        Text("Decision History")
          .font(captionSemibold)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        if inspector.didHistoryFail, inspector.historyDecisions.isEmpty {
          Button("Retry History") {
            loadHistory(reset: true)
          }
          .font(captionFont)
          .accessibilityIdentifier("harness.task-board.manage-item.triage.history.retry")
        } else if inspector.historyDecisions.isEmpty, !inspector.isHistoryLoading {
          Text("No automatic decisions recorded")
            .font(captionFont)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        } else {
          ForEach(inspector.historyDecisions, id: \.decisionId) { decision in
            historyRow(decision)
          }
        }
        if inspector.isHistoryLoading {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Loading triage history")
        } else if inspector.historyNextBeforeGeneration != nil {
          Button("Load Older") {
            loadHistory(reset: false)
          }
          .font(captionFont)
          .accessibilityIdentifier("harness.task-board.manage-item.triage.history.load-older")
        } else if inspector.historyReachedDisplayLimit {
          Text("Showing the newest 100 decisions")
            .font(captionFont)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.manage-item.triage.history")
  }

  private func historyRow(_ decision: TaskBoardTriageDecisionRecord) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(
        "#\(decision.generation) \(decision.verdict.title) · \(decision.reasonCode.title)"
      )
      .font(captionSemibold)
      if let detail = decision.reasonDetail, !detail.isEmpty {
        Text(detail)
          .font(captionFont)
      }
      Text(
        "\(decision.evaluatorIdentity) v\(decision.evaluatorVersion) · "
          + "\(decision.cause.title) · \(decision.decidedAt)"
      )
      .font(captionFont)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .textSelection(.enabled)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(
      "harness.task-board.manage-item.triage.history.\(decision.generation)"
    )
  }

  private func loadHistory(reset: Bool) {
    let store = actions.store
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: reset ? "Loading triage history" : "Loading older triage history") {
        await inspector.loadHistory(item: item, store: store, reset: reset)
      }
    )
  }

  private func reloadCurrentTriage() {
    let store = actions.store
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Reloading task board triage") {
        await inspector.load(item: item, store: store)
      }
    )
  }
}
