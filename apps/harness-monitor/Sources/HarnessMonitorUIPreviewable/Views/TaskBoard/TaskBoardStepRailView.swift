import HarnessMonitorKit
import SwiftUI

struct TaskBoardStepRailView: View {
  let store: HarnessMonitorStore
  let status: TaskBoardOrchestratorStatus
  let latestEvaluation: TaskBoardEvaluationSummary?
  let workspace: PolicyCanvasWorkspace?
  let targetItem: TaskBoardItem?
  let isActionInFlight: Bool
  let onOpenReview: (TaskBoardItem) -> Void

  @Environment(\.openWindow)
  var openWindow
  @Environment(\.openURL)
  var openURL
  @State private var state = TaskBoardStepRailState()

  var activeItem: TaskBoardItem? {
    state.delivery?.applied.item ?? state.pickedSelection?.item ?? targetItem
  }

  var stepRailState: TaskBoardStepRailState {
    state
  }

  private var controlsDisabled: Bool {
    isActionInFlight || state.isBusy || store.contentUI.dashboard.connectionState != .online
  }

  var body: some View {
    TaskBoardSection(title: "Manual Steps") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        TaskBoardStepRailTargetView(
          item: activeItem,
          isPicked: state.pickedSelection != nil
        )
        Label("Live manual operations", systemImage: "bolt.shield.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.caution)
          .accessibilityIdentifier("harness.task-board.step.live-mode")
        stepControls
        if let selection = state.pickedSelection {
          TaskBoardStepPromptPreview(prompt: selection.plan.renderedPrompt)
        }
        Divider()
        TaskBoardApprovalGrantsView(
          store: store,
          workspace: workspace,
          refreshID: approvalGrantRefreshID,
          isDisabled: controlsDisabled
        )
        Divider()
        HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingXL) {
          TaskBoardHeldDispatchesView(summary: status.heldDispatches)
            .frame(maxWidth: .infinity, alignment: .topLeading)
          TaskBoardPolicyGuardsView(
            workspace: workspace
          )
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
      .padding(HarnessMonitorTheme.spacingMD)
      .background(HarnessMonitorTheme.ink.opacity(0.025), in: .rect(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(HarnessMonitorTheme.ink.opacity(0.12))
      }
    }
    .confirmationDialog(
      confirmationTitle,
      isPresented: confirmationPresented,
      presenting: state.confirmation
    ) { confirmation in
      confirmationActions(confirmation)
    } message: { confirmation in
      Text(confirmationMessage(confirmation))
    }
    .onChange(of: status.stepMode) {
      if !status.stepMode {
        state.reset()
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.step-rail")
  }

  private var stepControls: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 185), spacing: HarnessMonitorTheme.spacingSM)],
      alignment: .leading,
      spacing: HarnessMonitorTheme.spacingSM
    ) {
      stepControl(
        1,
        "External Sync Live",
        "Pull and apply external sources",
        "arrow.triangle.2.circlepath"
      ) {
        state.confirmation = .externalSync
      }
      stepControl(
        2,
        "Evaluate Live",
        "Evaluate and apply the current target",
        "checkmark.seal"
      ) {
        state.confirmation = .evaluate(step: 2)
      }
      stepControl(3, "Pick Top", "Preview the top Todo prompt", "arrow.up.to.line") {
        enqueuePick()
      }
      stepControl(4, "Deliver Live", "Spawn the picked worker", "paperplane.fill") {
        state.confirmation = .deliver
      }
      stepControl(5, "Watch", "Open the spawned agent", "eye") {
        openSpawnedAgent()
      }
      stepControl(
        6,
        "Evaluate Live",
        "Evaluate and apply the delivered result",
        "waveform.path.ecg"
      ) {
        state.confirmation = .evaluate(step: 6)
      }
      stepControl(7, "Review", "Open linked task actions", "person.2.badge.gearshape") {
        openReview()
      }
      stepControl(8, "Complete", "Move the board item to Done", "checkmark.circle.fill") {
        state.confirmation = .complete
      }
    }
  }

  private func stepControl(
    _ step: Int,
    _ title: String,
    _ detail: String,
    _ systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    TaskBoardStepControl(
      step: step,
      title: title,
      detail: detail,
      systemImage: systemImage,
      tint: step == 4 || step == 8 ? HarnessMonitorTheme.accent : HarnessMonitorTheme.secondaryInk,
      isEnabled: isStepEnabled(step),
      isBusy: state.activeStep == step,
      isComplete: state.completedSteps.contains(step),
      action: action
    )
  }

  private func isStepEnabled(_ step: Int) -> Bool {
    guard !controlsDisabled else { return false }
    return switch step {
    case 2:
      activeItem != nil
    case 4:
      state.pickedSelection != nil
    case 5:
      state.delivery != nil || activeItem?.hasLinkedSessionTask == true
    case 6, 8:
      state.delivery != nil || activeItem?.hasLinkedSessionTask == true
    case 7:
      activeItem?.taskBoardGitHubURL != nil || activeItem?.hasLinkedSessionTask == true
    default:
      true
    }
  }

  private var confirmationPresented: Binding<Bool> {
    Binding(
      get: { state.confirmation != nil },
      set: { if !$0 { state.confirmation = nil } }
    )
  }

  private var confirmationTitle: String {
    switch state.confirmation {
    case .externalSync:
      "Run live external sync?"
    case .evaluate:
      "Run live task-board evaluation?"
    case .deliver:
      "Deliver and spawn this item?"
    case .complete:
      "Complete this board item?"
    case nil:
      "Confirm manual step"
    }
  }

  @ViewBuilder
  private func confirmationActions(
    _ confirmation: TaskBoardStepRailState.Confirmation
  ) -> some View {
    switch confirmation {
    case .externalSync:
      Button("Sync Live", role: .destructive) {
        state.confirmation = nil
        enqueueExternalSync()
      }
      .disabled(controlsDisabled)
    case .evaluate(let step):
      Button("Evaluate Live", role: .destructive) {
        state.confirmation = nil
        enqueueEvaluation(step: step)
      }
      .disabled(controlsDisabled)
    case .deliver:
      Button("Deliver Live", role: .destructive) {
        state.confirmation = nil
        enqueueDelivery()
      }
      .disabled(controlsDisabled)
    case .complete:
      Button("Complete", role: .destructive) {
        state.confirmation = nil
        enqueueCompletion()
      }
      .disabled(controlsDisabled)
    }
    Button("Cancel", role: .cancel) {}
  }

  private func confirmationMessage(_ confirmation: TaskBoardStepRailState.Confirmation) -> String {
    let title = activeItem?.title ?? "the current item"
    return switch confirmation {
    case .externalSync:
      "This pulls external task sources and applies changes to the live board."
    case .evaluate:
      "This evaluates \(title) and applies any resulting board transition."
    case .deliver:
      "This reserves \(title) in step mode and starts its managed worker."
    case .complete:
      "This moves \(title) to Done."
    }
  }

  private var approvalGrantRefreshID: TaskBoardApprovalGrantRefreshID {
    let activeCanvas = workspace?.canvases.first { $0.canvasId == workspace?.activeCanvasId }
    return TaskBoardApprovalGrantRefreshID(
      heldIntentIDs: status.heldDispatches.items.map(\.intentId).sorted(),
      activeCanvasID: workspace?.activeCanvasId,
      activeRevision: activeCanvas?.liveDocument?.revision ?? activeCanvas?.revision,
      lastRunID: status.lastRun?.runId,
      evaluationFingerprint: approvalEvaluationFingerprint,
      localGeneration: state.approvalRefreshGeneration
    )
  }

  private var approvalEvaluationFingerprint: TaskBoardApprovalEvaluationFingerprint? {
    latestEvaluation.map { TaskBoardApprovalEvaluationFingerprint(evaluation: $0) }
  }
}
