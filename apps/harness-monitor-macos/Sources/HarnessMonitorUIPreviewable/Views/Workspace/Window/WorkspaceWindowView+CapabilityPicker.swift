import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  var selectedAgentLaunchTitle: String {
    let options = agentCapabilityOptions
    let selection = viewModel.selectedLaunchSelection
    let match =
      options.first(where: { $0.transportChoices.contains(where: { $0.id == selection }) })
      ?? options.first
    return match?.title ?? "Agent"
  }

  var agentCapabilityOptions: [AgentCapabilityOption] {
    Self.agentCapabilityOptions(
      acpAgents: viewModel.availableAcpAgents,
      runtimeProbeResults: viewModel.runtimeProbeResults,
      sandboxed: store.daemonStatus?.manifest?.sandboxed == true,
      acpHostBridgeReady: store.hostBridgeCapabilityState(for: "acp") == .ready
    )
  }

  static func agentCapabilityOptions(
    acpAgents: [AcpAgentDescriptor],
    runtimeProbeResults: AcpRuntimeProbeResponse?,
    sandboxed: Bool = false,
    acpHostBridgeReady: Bool = true
  ) -> [AgentCapabilityOption] {
    AgentCapabilityCatalog.options(
      acpAgents: acpAgents,
      runtimeProbeResults: runtimeProbeResults,
      sandboxed: sandboxed,
      acpHostBridgeReady: acpHostBridgeReady
    )
  }

  static func normalizedLaunchSelection(
    options: [AgentCapabilityOption],
    selection: AgentLaunchSelection,
    fallbackRuntime: AgentTuiRuntime
  ) -> AgentLaunchSelection {
    AgentCapabilityCatalog.normalizedLaunchSelection(
      options: options,
      selection: selection,
      fallbackRuntime: fallbackRuntime
    )
  }

  static func firstProviderLaunchSelection(
    options: [AgentCapabilityOption],
    fallback: AgentLaunchSelection = HarnessMonitorAgentLaunchDefaults.startupFallbackSelection
  ) -> AgentLaunchSelection {
    AgentCapabilityCatalog.firstProviderLaunchSelection(options: options, fallback: fallback)
  }

  static func defaultLaunchSelection(
    providerID: String,
    options: [AgentCapabilityOption],
    fallback: AgentLaunchSelection
  ) -> AgentLaunchSelection {
    AgentCapabilityCatalog.defaultLaunchSelection(
      providerID: providerID,
      options: options,
      fallback: fallback
    )
  }

  static func transportChoices(
    runtime: AgentTuiRuntime,
    descriptor: AcpAgentDescriptor?
  ) -> [AgentCapabilityTransportChoice] {
    AgentCapabilityCatalog.transportChoices(runtime: runtime, descriptor: descriptor)
  }

  static func probeResult(
    for descriptor: AcpAgentDescriptor,
    runtimeProbeResults: AcpRuntimeProbeResponse?
  ) -> AcpRuntimeProbe? {
    AgentCapabilityCatalog.probeResult(
      for: descriptor,
      runtimeProbeResults: runtimeProbeResults
    )
  }
}
