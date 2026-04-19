import HarnessMonitorKit

extension AgentTuiWindowView {
  func terminalRuntimeCatalog(_ formModel: ViewModel) -> RuntimeModelCatalog? {
    formModel.availableRuntimeModels.first { $0.runtime == formModel.runtime.rawValue }
  }

  func codexCatalog(_ formModel: ViewModel) -> RuntimeModelCatalog? {
    formModel.availableRuntimeModels.first { $0.runtime == "codex" }
  }
}
