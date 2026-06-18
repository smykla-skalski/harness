import Foundation

// Wire maps for the SessionDetail.agentActivity member (AgentToolActivitySummary) and its pending
// user-prompt tree. Counts narrow UInt -> Int. AgentPendingUserPrompt replays the hand init's
// legacy fallback: an empty questions list plus a non-empty message synthesizes one question.

extension AgentPendingUserPromptOption {
  init(wire: AskUserQuestionOptionWire) {
    self.init(label: wire.label, description: wire.description)
  }
}

extension AgentPendingUserPromptQuestion {
  init(wire: AskUserQuestionPromptWire) {
    self.init(
      question: wire.question,
      header: wire.header,
      options: wire.options.map(AgentPendingUserPromptOption.init(wire:)),
      multiSelect: wire.multiSelect
    )
  }
}

extension AgentPendingUserPrompt {
  init(wire: AgentPendingUserPromptWire) {
    let questions: [AgentPendingUserPromptQuestion]
    if !wire.questions.isEmpty {
      questions = wire.questions.map(AgentPendingUserPromptQuestion.init(wire:))
    } else if let message = wire.message,
      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      questions = [AgentPendingUserPromptQuestion(question: message)]
    } else {
      questions = []
    }
    self.init(toolName: wire.toolName, waitingSince: wire.waitingSince, questions: questions)
  }
}

extension AgentToolActivitySummary {
  init(wire: AgentToolActivitySummaryWire) {
    self.init(
      agentId: wire.agentId,
      runtime: wire.runtime,
      toolInvocationCount: Int(wire.toolInvocationCount),
      toolResultCount: Int(wire.toolResultCount),
      toolErrorCount: Int(wire.toolErrorCount),
      latestToolName: wire.latestToolName,
      latestEventAt: wire.latestEventAt,
      recentTools: wire.recentTools,
      pendingUserPrompt: wire.pendingUserPrompt.map(AgentPendingUserPrompt.init(wire:))
    )
  }
}
