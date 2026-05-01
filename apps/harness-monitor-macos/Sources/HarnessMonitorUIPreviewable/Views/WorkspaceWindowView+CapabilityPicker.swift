import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  var selectedAgentLaunchTitle: String {
    switch viewModel.selectedLaunchSelection {
    case .tui(let runtime):
      runtime.title
    case .acp(let id):
      viewModel.availableAcpAgents.first { $0.id == id }?.displayName ?? "Agent"
    }
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
    var rows: [AgentCapabilityOption] = AgentTuiRuntime.allCases.map { runtime in
      let descriptor = acpAgents.first { representsSameCapability($0, as: runtime) }
      return AgentCapabilityOption(
        id: runtime.rawValue,
        title: runtime.title,
        transportChoices: transportChoices(runtime: runtime, descriptor: descriptor),
        doctorProbe: descriptor?.doctorProbe,
        probe: descriptor.flatMap {
          probeResult(for: $0, runtimeProbeResults: runtimeProbeResults)
        },
        installHint: descriptor?.installHint,
        sandboxed: sandboxed,
        acpHostBridgeReady: acpHostBridgeReady
      )
    }
    for descriptor in acpAgents
    where !rows.contains(where: {
      $0.id == descriptor.id
        || canonicalCapabilityName($0.title) == canonicalCapabilityName(descriptor.displayName)
    }) {
      rows.append(
        AgentCapabilityOption(
          id: descriptor.id,
          title: descriptor.displayName,
          transportChoices: [
            AgentCapabilityTransportChoice(
              id: .acp(descriptor.id),
              title: "Project access",
              capabilities: descriptor.capabilities
            )
          ],
          doctorProbe: descriptor.doctorProbe,
          probe: probeResult(for: descriptor, runtimeProbeResults: runtimeProbeResults),
          installHint: descriptor.installHint,
          sandboxed: sandboxed,
          acpHostBridgeReady: acpHostBridgeReady
        )
      )
    }
    return rows
  }

  static func normalizedLaunchSelection(
    options: [AgentCapabilityOption],
    selection: AgentLaunchSelection,
    fallbackRuntime: AgentTuiRuntime
  ) -> AgentLaunchSelection {
    if let selectedOption = options.first(where: { option in
      option.transportChoices.contains { $0.id == selection }
    }) {
      return selectedOption.normalizedSelection(for: selection)
    }

    if let runtimeOption = options.first(where: { $0.id == fallbackRuntime.rawValue }) {
      return runtimeOption.normalizedSelection(for: .tui(fallbackRuntime))
    }

    if let firstEnabled = options.first(where: \.isEnabled) {
      return firstEnabled.normalizedSelection(for: firstEnabled.transportChoices[0].id)
    }

    return selection
  }

  static func transportChoices(
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
          title: "Project access",
          capabilities: descriptor.capabilities
        )
      )
    }
    return choices
  }

  static func probeResult(
    for descriptor: AcpAgentDescriptor,
    runtimeProbeResults: AcpRuntimeProbeResponse?
  ) -> AcpRuntimeProbe? {
    runtimeProbeResults?.probes.first { $0.agentId == descriptor.id }
  }

  private static func representsSameCapability(
    _ descriptor: AcpAgentDescriptor,
    as runtime: AgentTuiRuntime
  ) -> Bool {
    descriptor.id == runtime.rawValue
      || canonicalCapabilityName(descriptor.displayName) == canonicalCapabilityName(runtime.title)
  }

  private static func canonicalCapabilityName(_ value: String) -> String {
    let ignoredTokens: Set<String> = ["agent", "cli", "github", "google"]
    let tokens =
      value
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
      .filter { !ignoredTokens.contains($0) }

    return tokens.joined()
  }
}
