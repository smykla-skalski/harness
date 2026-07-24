import HarnessMonitorKit
import SwiftUI

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
      pendingEscalationRow
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

  @ViewBuilder private var pendingEscalationRow: some View {
    if let status = inspector.current?.pendingEscalationStatus {
      Text(status.title)
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityIdentifier("harness.task-board.manage-item.triage.escalation")
    }
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
