import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  @MainActor
  func startAcpAgentIfSelected() async -> Bool {
    guard case .acp(let agentID) = viewModel.selectedLaunchSelection else {
      return false
    }
    let capabilities =
      viewModel.availableAcpAgents.first(where: { $0.id == agentID })?.capabilities ?? []
    let startSessionID = viewModel.selection.sessionID ?? viewModel.createSessionID
    let started = await store.startAcpAgent(
      agentID: agentID,
      role: viewModel.selectedRole,
      fallbackRole: viewModel.selectedRole == .leader ? viewModel.selectedAcpFallbackRole : nil,
      capabilities: capabilities,
      name: viewModel.name,
      prompt: viewModel.prompt,
      projectDir: trimmedProjectDir,
      persona: viewModel.selectedPersona,
      sessionID: startSessionID
    )
    guard started != nil else {
      viewModel.startTuiPhase = "failed"
      viewModel.isSubmitting = false
      return true
    }
    guard let started else {
      return true
    }
    viewModel.name = ""
    viewModel.prompt = ""
    viewModel.projectDir = ""
    viewModel.argvOverride = ""
    viewModel.selectedPersona = nil
    viewModel.selectedAcpFallbackRole = .worker
    viewModel.selectedRole = .worker
    await store.refreshSessionDetail(sessionID: started.sessionId)
    viewModel.createSessionID = started.sessionId
    viewModel.selection = .agent(
      sessionID: started.sessionId,
      agentID: started.agentId
    )
    viewModel.startTuiPhase = "done"
    viewModel.isSubmitting = false
    return true
  }
}
