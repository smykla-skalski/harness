import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  @MainActor
  func startAcpAgentIfSelected() async -> Bool {
    guard case .acp(let agentID) = viewModel.selectedLaunchSelection else {
      return false
    }
    let started = await store.startAcpAgent(
      agentID: agentID,
      prompt: viewModel.prompt,
      projectDir: trimmedProjectDir
    )
    guard started != nil else {
      viewModel.startTuiPhase = "failed"
      viewModel.isSubmitting = false
      return true
    }
    viewModel.name = ""
    viewModel.prompt = ""
    viewModel.projectDir = ""
    viewModel.argvOverride = ""
    viewModel.selectedRole = .worker
    viewModel.startTuiPhase = "done"
    viewModel.isSubmitting = false
    refresh()
    return true
  }
}
