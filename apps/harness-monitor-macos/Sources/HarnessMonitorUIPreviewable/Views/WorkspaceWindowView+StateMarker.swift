import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  @MainActor var currentStateMarker: String {
    func formatSize(_ size: AgentTuiSize?) -> String {
      guard let size else {
        return "none"
      }
      return "\(size.rows)x\(size.cols)"
    }

    func formatPoints(_ size: CGSize?) -> String {
      guard let size else {
        return "none"
      }
      return "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    let selectedSessionLabel = "session=\(store.selectedSessionID ?? "none")"
    let readOnlyLabel = "readOnly=\(store.isSessionReadOnly)"
    let focusedFieldLabel = "focus=\(focusedField.map(String.init(describing:)) ?? "none")"
    let startTuiLabel = "startTui=\(viewModel.startTuiAttemptCount):\(viewModel.startTuiPhase)"
    let codexStartLabel =
      "codexStart=\(viewModel.codexStartAttemptCount):\(viewModel.codexStartResult)"
    let codexReadyLabel =
      "codexReady=\(viewModel.createMode == .codex ? canStartCodex : false)"
    let codexPromptLengthLabel =
      "codexPromptLen=\(viewModel.createMode == .codex ? trimmedCodexPrompt.count : 0)"
    let toastLabel: String = {
      guard let feedback = store.toast.activeFeedback.first else {
        return "toast=none"
      }
      let severity =
        switch feedback.severity {
        case .success:
          "success"
        case .failure:
          "failure"
        }
      let message = feedback.message.replacingOccurrences(of: ",", with: ";")
      return "toast=\(severity):\(message)"
    }()
    switch viewModel.selection {
    case .create:
      return [
        "selection=create",
        selectedSessionLabel,
        readOnlyLabel,
        focusedFieldLabel,
        startTuiLabel,
        codexStartLabel,
        codexReadyLabel,
        codexPromptLengthLabel,
        toastLabel,
      ].joined(separator: ",")
    case .decisions(let sessionID):
      return [
        "selection=decisions:\(sessionID ?? "none")",
        selectedSessionLabel,
        readOnlyLabel,
        codexStartLabel,
        toastLabel,
      ].joined(separator: ",")
    case .decision(let sessionID, let decisionID):
      return [
        "selection=decision:\(sessionID ?? "none"):\(decisionID)",
        selectedSessionLabel,
        readOnlyLabel,
        codexStartLabel,
        toastLabel,
      ].joined(separator: ",")
    case .terminal(_, let sessionID):
      let status = selectedSessionTui?.status.rawValue ?? "missing"
      let sizeLabel: String = {
        guard let selectedSessionTui else {
          return "size=missing"
        }
        return "size=\(selectedSessionTui.size.rows)x\(selectedSessionTui.size.cols)"
      }()
      return [
        "selection=session:\(sessionID)",
        "status=\(status)",
        "wrap=\(viewModel.wrapLines)",
        sizeLabel,
        "viewportPts=\(formatPoints(viewModel.lastMeasuredViewportPoints))",
        "measured=\(formatSize(viewModel.lastMeasuredViewportTerminalSize))",
        "stabilized=\(formatSize(viewModel.lastMeasuredViewportSize))",
        "expected=\(formatSize(viewModel.expectedSize))",
        "pending=\(formatSize(viewModel.pendingViewportResizeTarget))",
        "controls=\(viewModel.rows)x\(viewModel.cols)",
        "reconciling=\(liveViewportIsReconciling)",
        selectedSessionLabel,
        readOnlyLabel,
        codexStartLabel,
        toastLabel,
      ].joined(separator: ",")
    case .codex(_, let runID):
      let status = selectedCodexRun?.status.rawValue ?? "missing"
      let approvalCount = selectedCodexApprovalItems.count
      return [
        "selection=codex:\(runID)",
        "status=\(status)",
        "approvals=\(approvalCount)",
        selectedSessionLabel,
        readOnlyLabel,
        codexStartLabel,
        toastLabel,
      ].joined(separator: ",")
    case .agent(_, let agentID):
      let agentStatus =
        store.selectedSession?.agents.first(where: { $0.agentId == agentID })?.status.rawValue
        ?? "missing"
      return [
        "selection=agent:\(agentID)",
        "status=\(agentStatus)",
        selectedSessionLabel,
        readOnlyLabel,
        codexStartLabel,
        toastLabel,
      ].joined(separator: ",")
    case .task(_, let taskID):
      let taskStatus =
        store.selectedSession?.tasks.first(where: { $0.taskId == taskID })?.status.rawValue
        ?? "missing"
      return [
        "selection=task:\(taskID)",
        "status=\(taskStatus)",
        selectedSessionLabel,
        readOnlyLabel,
        codexStartLabel,
        toastLabel,
      ].joined(separator: ",")
    }
  }
}
