import HarnessMonitorKit

enum SessionWindowCreateFormCatalogs {
  @MainActor
  static func fallbackAgentOptions(store: HarnessMonitorStore) -> [AgentCapabilityOption] {
    AgentCapabilityCatalog.options(
      acpAgents: [],
      runtimeProbeResults: nil,
      sandboxed: store.daemonStatus?.manifest?.sandboxed == true,
      acpHostBridgeReady: store.hostBridgeCapabilityState(for: "acp") == .ready
    )
  }

  @MainActor
  static func loadAgentOptions(store: HarnessMonitorStore) async -> [AgentCapabilityOption] {
    async let acpAgents = store.fetchAcpAgentDescriptors()
    async let runtimeProbeResults = store.fetchRuntimeProbeResults()
    return AgentCapabilityCatalog.options(
      acpAgents: await acpAgents,
      runtimeProbeResults: await runtimeProbeResults,
      sandboxed: store.daemonStatus?.manifest?.sandboxed == true,
      acpHostBridgeReady: store.hostBridgeCapabilityState(for: "acp") == .ready
    )
  }

  static func normalizedLaunchSelection(
    draft: SessionCreateDraft,
    options: [AgentCapabilityOption]
  ) -> AgentLaunchSelection {
    AgentCapabilityCatalog.normalizedLaunchSelection(
      options: options,
      selection: draft.launchSelection,
      fallbackRuntime: draft.launchSelection.preferredRuntime
    )
  }
}

extension SessionCreateDraft {
  var launchSelection: AgentLaunchSelection {
    AgentLaunchSelection(storageKey: runtime)
      ?? AgentTuiRuntime(rawValue: runtime).map(AgentLaunchSelection.tui)
      ?? HarnessMonitorAgentLaunchDefaults.startupFallbackSelection
  }
}
