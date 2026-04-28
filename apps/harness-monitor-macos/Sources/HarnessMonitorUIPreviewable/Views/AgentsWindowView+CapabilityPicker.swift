import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  var selectedAgentLaunchTitle: String {
    switch viewModel.selectedLaunchSelection {
    case .tui(let runtime):
      runtime.title
    case .acp(let id):
      viewModel.availableAcpAgents.first { $0.id == id }?.displayName ?? "Agent"
    }
  }

  var agentCapabilityOptions: [AgentCapabilityOption] {
    var rows: [AgentCapabilityOption] = AgentTuiRuntime.allCases.map { runtime in
      let descriptor = viewModel.availableAcpAgents.first {
        normalizedAgentName($0.displayName) == normalizedAgentName(runtime.title)
      }
      return AgentCapabilityOption(
        id: runtime.rawValue,
        title: runtime.title,
        transportChoices: transportChoices(runtime: runtime, descriptor: descriptor),
        probe: descriptor.flatMap(probeResult(for:)),
        installHint: descriptor?.installHint
      )
    }
    for descriptor in viewModel.availableAcpAgents
    where !rows.contains(where: {
      normalizedAgentName($0.title) == normalizedAgentName(descriptor.displayName)
    }) {
      rows.append(
        AgentCapabilityOption(
          id: descriptor.id,
          title: descriptor.displayName,
          transportChoices: [
            AgentCapabilityTransportChoice(
              id: .acp(descriptor.id),
              title: "Filesystem + terminal tools",
              capabilities: descriptor.capabilities
            )
          ],
          probe: probeResult(for: descriptor),
          installHint: descriptor.installHint
        )
      )
    }
    return rows
  }

  func transportChoices(
    runtime: AgentTuiRuntime,
    descriptor: AcpAgentDescriptor?
  ) -> [AgentCapabilityTransportChoice] {
    var choices = [
      AgentCapabilityTransportChoice(
        id: .tui(runtime),
        title: "Terminal screen",
        capabilities: ["streaming", "multi-turn"]
      )
    ]
    if let descriptor {
      choices.append(
        AgentCapabilityTransportChoice(
          id: .acp(descriptor.id),
          title: "Filesystem + terminal tools",
          capabilities: descriptor.capabilities
        )
      )
    }
    return choices
  }

  func probeResult(for descriptor: AcpAgentDescriptor) -> AcpRuntimeProbe? {
    viewModel.runtimeProbeResults?.probes.first { $0.agentId == descriptor.id }
  }

  func normalizedAgentName(_ value: String) -> String {
    value
      .lowercased()
      .replacingOccurrences(of: "github ", with: "")
      .replacingOccurrences(of: " ", with: "")
  }
}
