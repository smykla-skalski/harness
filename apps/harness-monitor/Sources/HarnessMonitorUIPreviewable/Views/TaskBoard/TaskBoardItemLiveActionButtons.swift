import HarnessMonitorKit
import SwiftUI

struct TaskBoardItemLiveActionButtons: View {
  let item: TaskBoardItem
  let metrics: TaskBoardOverviewMetrics
  let captionFont: Font
  let isActionInFlight: Bool
  let runOnceDryRun: Bool
  let evaluateDryRun: Bool
  let actions: TaskBoardOverviewActions
  let evaluatePreviewState: TaskBoardEvaluatePreviewState

  @State private var pendingAction: LiveAction?

  private var canRunOnce: Bool { actions.canRunOrchestratorOnce }
  private var canEvaluate: Bool { actions.canEvaluateItem || actions.canEvaluateBoard }

  var body: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingSM,
      lineSpacing: HarnessMonitorTheme.spacingSM
    ) {
      runOnceButton
      evaluateButton
    }
    .confirmationDialog(
      pendingAction?.title ?? "Run live task-board action?",
      isPresented: Binding(
        get: { pendingAction != nil },
        set: { if !$0 { pendingAction = nil } }
      ),
      presenting: pendingAction
    ) { action in
      Button(action.actionTitle, role: .destructive) {
        pendingAction = nil
        perform(action)
      }
      .disabled(isActionInFlight)
      Button("Cancel", role: .cancel) {}
    } message: { action in
      Text(action.message(for: item.title))
    }
  }

  private var runOnceButton: some View {
    Button {
      if runOnceDryRun {
        runOnce()
      } else {
        pendingAction = .runOnce
      }
    } label: {
      Label(runOnceDryRun ? "Preview Run Once" : "Run Once Live", systemImage: "play.circle")
        .font(captionFont)
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight || !canRunOnce)
    .help(
      runOnceDryRun
        ? "Preview one orchestrator run without applying changes"
        : "Run one live orchestrator tick after confirmation"
    )
  }

  private var evaluateButton: some View {
    Button {
      if evaluateDryRun {
        evaluate()
      } else {
        pendingAction = .evaluate
      }
    } label: {
      Label(
        evaluateDryRun ? "Preview Item" : "Evaluate Item Live",
        systemImage: "checkmark.seal"
      )
      .font(captionFont)
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight || !canEvaluate)
    .help(
      evaluateDryRun
        ? "Preview this board item's evaluation without applying changes"
        : "Evaluate this item and apply live transitions after confirmation"
    )
  }

  private func perform(_ action: LiveAction) {
    switch action {
    case .runOnce:
      runOnce()
    case .evaluate:
      evaluate()
    }
  }

  private func runOnce() {
    actions.runTaskBoardOrchestratorOnce(
      TaskBoardOverviewItemBehavior.runOnceRequest(for: item, dryRun: runOnceDryRun)
    )
  }

  private func evaluate() {
    actions.evaluateTaskBoardItemOrPreview(
      item,
      dryRun: evaluateDryRun,
      previewState: evaluatePreviewState
    )
  }
}

extension TaskBoardItemLiveActionButtons {
  fileprivate enum LiveAction {
    case runOnce
    case evaluate

    var title: String {
      switch self {
      case .runOnce:
        "Run this item live?"
      case .evaluate:
        "Evaluate this item live?"
      }
    }

    var actionTitle: String {
      switch self {
      case .runOnce:
        "Run Once Live"
      case .evaluate:
        "Evaluate Live"
      }
    }

    func message(for title: String) -> String {
      switch self {
      case .runOnce:
        "This runs a live orchestrator tick for \(title) and can dispatch work."
      case .evaluate:
        "This evaluates \(title) and applies any resulting item transition."
      }
    }
  }
}

struct TaskBoardItemSyncActionButton: View {
  let metrics: TaskBoardOverviewMetrics
  let captionFont: Font
  let isActionInFlight: Bool
  let actions: TaskBoardOverviewActions

  @State private var isConfirming = false

  var body: some View {
    if actions.canRefreshBoard {
      Button {
        isConfirming = true
      } label: {
        Label("Sync Live", systemImage: "arrow.clockwise")
          .font(captionFont)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help("Pull external sources and apply live board changes after confirmation")
      .accessibilityIdentifier("harness.task-board.manage-item.refresh")
      .confirmationDialog("Sync the live task board?", isPresented: $isConfirming) {
        Button("Sync Live", role: .destructive) {
          actions.refreshTaskBoard()
        }
        .disabled(isActionInFlight)
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This pulls external task sources and applies changes to the live board.")
      }
    }
  }
}
