import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  @MainActor
  func startAcpAgentIfSelected() async -> Bool {
    guard case .acp(let descriptorIDValue) = viewModel.selectedLaunchSelection else {
      return false
    }
    let descriptorIdentity = AcpDescriptorID(rawValue: descriptorIDValue)
    let capabilities =
      viewModel.availableAcpAgents.first(where: { $0.descriptorIdentity == descriptorIdentity })?
      .capabilities ?? []
    let startSessionID = resolvedCreateSessionID
    let started = await store.startAcpAgent(
      descriptorID: descriptorIdentity,
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
