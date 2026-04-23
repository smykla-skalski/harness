import Foundation
import HarnessMonitorKit

extension AgentTuiWindowView {
  func resolveCodexApproval(_ item: CodexApprovalItem, run: CodexRunSnapshot, actionID: String) {
    viewModel.resolvingCodexApprovalID = item.approvalID
    Task {
      defer { viewModel.resolvingCodexApprovalID = nil }

      if let decisionID = item.decisionID {
        let handler = store.supervisorDecisionActionHandler()
        await handler.resolve(
          decisionID: decisionID,
          outcome: DecisionOutcome(chosenActionID: actionID, note: nil)
        )
        return
      }

      guard let decision = CodexApprovalDecision(rawValue: actionID) else {
        return
      }
      _ = await store.resolveCodexApproval(
        runID: run.runId,
        approvalID: item.approvalID,
        decision: decision
      )
    }
  }

  static func codexApprovalItems(
    for run: CodexRunSnapshot,
    decisions: [Decision]
  ) -> [CodexApprovalItem] {
    let requestsByApprovalID = Dictionary(
      uniqueKeysWithValues: run.pendingApprovals.map { ($0.approvalId, $0) }
    )
    let decisionItems = decisions.compactMap { decision in
      codexApprovalItem(
        from: decision,
        run: run,
        requestsByApprovalID: requestsByApprovalID
      )
    }
    let decisionItemByApprovalID = Dictionary(
      uniqueKeysWithValues: decisionItems.map { ($0.approvalID, $0) }
    )

    var items = run.pendingApprovals.map { approval in
      decisionItemByApprovalID[approval.approvalId]
        ?? CodexApprovalItem.fallback(from: approval)
    }
    items.append(
      contentsOf: decisionItems.filter { requestsByApprovalID[$0.approvalID] == nil }
    )
    return items
  }

  private static func codexApprovalItem(
    from decision: Decision,
    run: CodexRunSnapshot,
    requestsByApprovalID: [String: CodexApprovalRequest]
  ) -> CodexApprovalItem? {
    guard decision.ruleID == "codex-approval", decision.sessionID == run.sessionId else {
      return nil
    }
    guard
      let context = decodeCodexApprovalContext(from: decision.contextJSON),
      context.agentID == run.runId
    else {
      return nil
    }
    let matchedRequest = requestsByApprovalID[context.approvalID]
    let actions = decodeCodexApprovalActions(from: decision.suggestedActionsJSON)
    return CodexApprovalItem(
      approvalID: context.approvalID,
      title: matchedRequest?.title ?? decision.summary,
      detail: matchedRequest?.detail ?? "",
      decisionID: decision.id,
      actions: actions.isEmpty ? CodexApprovalActionButtonModel.defaults : actions
    )
  }

  private static func decodeCodexApprovalContext(from json: String) -> CodexApprovalContext? {
    try? JSONDecoder().decode(CodexApprovalContext.self, from: Data(json.utf8))
  }

  private static func decodeCodexApprovalActions(
    from json: String
  ) -> [CodexApprovalActionButtonModel] {
    guard
      let actions = try? JSONDecoder().decode([SuggestedAction].self, from: Data(json.utf8))
    else {
      return []
    }
    return actions.map { action in
      CodexApprovalActionButtonModel(id: action.id, title: action.title)
    }
  }
}

struct CodexApprovalItem: Identifiable, Equatable {
  let approvalID: String
  let title: String
  let detail: String
  let decisionID: String?
  let actions: [CodexApprovalActionButtonModel]

  var id: String { approvalID }

  static func fallback(from approval: CodexApprovalRequest) -> Self {
    Self(
      approvalID: approval.approvalId,
      title: approval.title,
      detail: approval.detail,
      decisionID: nil,
      actions: CodexApprovalActionButtonModel.defaults
    )
  }
}

struct CodexApprovalActionButtonModel: Identifiable, Equatable {
  let id: String
  let title: String

  static let defaults: [Self] = [
    .init(id: CodexApprovalDecision.accept.rawValue, title: "Accept"),
    .init(id: CodexApprovalDecision.acceptForSession.rawValue, title: "Accept for session"),
    .init(id: CodexApprovalDecision.decline.rawValue, title: "Decline"),
    .init(id: CodexApprovalDecision.cancel.rawValue, title: "Cancel"),
  ]
}

private struct CodexApprovalContext: Decodable {
  let approvalID: String
  let agentID: String
}
