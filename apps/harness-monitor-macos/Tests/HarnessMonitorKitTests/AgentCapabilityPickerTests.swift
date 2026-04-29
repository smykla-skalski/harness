import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Agent capability picker helpers")
@MainActor
struct AgentCapabilityPickerTests {
  @Test("built-in runtimes merge matching ACP descriptors into one row")
  func mergesMatchingAcpDescriptors() throws {
    let options = AgentsWindowView.agentCapabilityOptions(
      acpAgents: [
        descriptor(id: "copilot", displayName: "GitHub Copilot"),
        descriptor(id: "gemini", displayName: "Gemini CLI"),
        descriptor(id: "custom-agent", displayName: "Custom Agent"),
      ],
      runtimeProbeResults: nil
    )

    #expect(options.count == AgentTuiRuntime.allCases.count + 1)
    #expect(Set(options.map(\.id)).count == options.count)

    let gemini = try #require(options.first { $0.id == AgentTuiRuntime.gemini.rawValue })
    #expect(gemini.transportChoices.map(\.id) == [.tui(.gemini), .acp("gemini")])

    let custom = try #require(options.first { $0.id == "custom-agent" })
    #expect(custom.transportChoices.map(\.id) == [.acp("custom-agent")])
  }

  @Test("row selection clamps stale global values to rendered transport tags")
  func clampsSelectionToRenderedChoices() {
    let option = AgentCapabilityOption(
      id: "gemini",
      title: "Gemini",
      transportChoices: [
        AgentCapabilityTransportChoice(
          id: .tui(.gemini),
          title: "Terminal screen",
          capabilities: ["streaming", "multi-turn"]
        ),
        AgentCapabilityTransportChoice(
          id: .acp("gemini"),
          title: "Filesystem + terminal tools",
          capabilities: ["fs.read", "fs.write"]
        ),
      ],
      doctorProbe: AcpDoctorProbe(command: "gemini", args: ["--version"]),
      probe: nil,
      installHint: nil,
      sandboxed: false,
      acpHostBridgeReady: true
    )

    #expect(option.normalizedSelection(for: .tui(.codex)) == .tui(.gemini))
    #expect(option.transportChoice(for: .tui(.codex)).id == .tui(.gemini))
    #expect(option.normalizedSelection(for: .acp("gemini")) == .acp("gemini"))
  }

  @Test("missing ACP probe keeps ACP transport pending instead of ready")
  func missingAcpProbeStaysPending() {
    let option = AgentCapabilityOption(
      id: "gemini",
      title: "Gemini",
      transportChoices: [
        AgentCapabilityTransportChoice(
          id: .tui(.gemini),
          title: "Terminal screen",
          capabilities: ["streaming", "multi-turn"]
        ),
        AgentCapabilityTransportChoice(
          id: .acp("gemini"),
          title: "Filesystem + terminal tools",
          capabilities: ["fs.read", "fs.write"]
        ),
      ],
      doctorProbe: AcpDoctorProbe(command: "gemini", args: ["--version"]),
      probe: nil,
      installHint: nil,
      sandboxed: false,
      acpHostBridgeReady: true
    )

    #expect(option.statusText == "Checking")
    #expect(option.hasPendingAcpProbe)
    #expect(!option.isEnabled(option.transportChoice(for: .acp("gemini"))))
    #expect(option.normalizedSelection(for: .acp("gemini")) == .tui(.gemini))
    #expect(option.doctorProbeText == "Doctor probe: gemini --version · Probe pending")
  }

  @Test("missing ACP binary disables only ACP transport when terminal transport exists")
  func missingAcpBinaryDoesNotDisableTerminalTransport() {
    let option = AgentCapabilityOption(
      id: "gemini",
      title: "Gemini",
      transportChoices: [
        AgentCapabilityTransportChoice(
          id: .tui(.gemini),
          title: "Terminal screen",
          capabilities: ["streaming", "multi-turn"]
        ),
        AgentCapabilityTransportChoice(
          id: .acp("gemini"),
          title: "Filesystem + terminal tools",
          capabilities: ["fs.read", "fs.write"]
        ),
      ],
      doctorProbe: AcpDoctorProbe(command: "gemini", args: ["--version"]),
      probe: AcpRuntimeProbe(
        agentId: "gemini",
        displayName: "Gemini CLI",
        binaryPresent: false,
        authState: .unavailable
      ),
      installHint: "Install Gemini",
      sandboxed: false,
      acpHostBridgeReady: true
    )

    #expect(option.isEnabled)
    #expect(option.statusText == "Install required")
    #expect(option.isEnabled(option.transportChoice(for: .tui(.gemini))))
    #expect(!option.isEnabled(option.transportChoice(for: .acp("gemini"))))
    #expect(option.showsInstallCTA)
    #expect(option.installActionTitle == "Copy install instructions")
    #expect(option.doctorProbeText == "Doctor probe: gemini --version · Missing")
  }

  @Test("sandboxed monitor disables ACP transport even when binary exists")
  func sandboxedMonitorDisablesAcpTransport() throws {
    let options = AgentsWindowView.agentCapabilityOptions(
      acpAgents: [descriptor(id: "copilot", displayName: "GitHub Copilot")],
      runtimeProbeResults: AcpRuntimeProbeResponse(
        probes: [
          AcpRuntimeProbe(
            agentId: "copilot",
            displayName: "GitHub Copilot",
            binaryPresent: true,
            authState: .ready
          )
        ],
        checkedAt: "2026-04-28T22:00:00Z"
      ),
      sandboxed: true,
      acpHostBridgeReady: false
    )

    let copilot = try #require(options.first { $0.id == AgentTuiRuntime.copilot.rawValue })
    #expect(copilot.normalizedSelection(for: .acp("copilot")) == .tui(.copilot))
    #expect(!copilot.isEnabled(copilot.transportChoice(for: .acp("copilot"))))
    #expect(copilot.isEnabled(copilot.transportChoice(for: .tui(.copilot))))
  }

  @Test(
    "sandboxed monitor keeps ACP transport enabled via host bridge even when local probe is missing"
  )
  func sandboxedMonitorAllowsAcpTransportViaHostBridge() throws {
    let options = AgentsWindowView.agentCapabilityOptions(
      acpAgents: [descriptor(id: "copilot", displayName: "GitHub Copilot")],
      runtimeProbeResults: AcpRuntimeProbeResponse(
        probes: [
          AcpRuntimeProbe(
            agentId: "copilot",
            displayName: "GitHub Copilot",
            binaryPresent: false,
            authState: .unavailable
          )
        ],
        checkedAt: "2026-04-28T22:05:00Z"
      ),
      sandboxed: true,
      acpHostBridgeReady: true
    )

    let copilot = try #require(options.first { $0.id == AgentTuiRuntime.copilot.rawValue })
    #expect(copilot.normalizedSelection(for: .acp("copilot")) == .acp("copilot"))
    #expect(copilot.isEnabled(copilot.transportChoice(for: .acp("copilot"))))
  }

  @Test("capability labels use human capability names")
  func capabilityLabelsUseHumanCapabilityNames() {
    let option = AgentCapabilityOption(
      id: "copilot",
      title: "GitHub Copilot",
      transportChoices: [
        AgentCapabilityTransportChoice(
          id: .acp("copilot"),
          title: "Filesystem + terminal tools",
          capabilities: ["fs.read", "fs.write", "terminal.spawn"]
        )
      ],
      doctorProbe: AcpDoctorProbe(command: "copilot", args: ["--version"]),
      probe: AcpRuntimeProbe(
        agentId: "copilot",
        displayName: "GitHub Copilot",
        binaryPresent: false,
        authState: .unavailable
      ),
      installHint: "Install GitHub Copilot CLI and sign in.",
      sandboxed: false,
      acpHostBridgeReady: true
    )

    #expect(option.accessibilityLabel == "GitHub Copilot, install required")
    #expect(
      option.transportChoices[0].capabilityLabels
        == ["filesystem read", "filesystem write", "terminal spawn"]
    )
    #expect(option.installAccessibilityHint == "Copies install instructions for GitHub Copilot")
  }

  @Test("missing selected ACP descriptor falls back to runtime TUI choice")
  func missingSelectedAcpDescriptorFallsBackToRuntime() {
    let options = AgentsWindowView.agentCapabilityOptions(
      acpAgents: [descriptor(id: "copilot", displayName: "GitHub Copilot")],
      runtimeProbeResults: AcpRuntimeProbeResponse(
        probes: [
          AcpRuntimeProbe(
            agentId: "copilot",
            displayName: "GitHub Copilot",
            binaryPresent: true,
            authState: .ready
          )
        ],
        checkedAt: "2026-04-28T22:10:00Z"
      )
    )

    let normalizedSelection = AgentsWindowView.normalizedLaunchSelection(
      options: options,
      selection: .acp("removed-agent"),
      fallbackRuntime: .gemini
    )

    #expect(normalizedSelection == .tui(.gemini))
  }

  private func descriptor(id: String, displayName: String) -> AcpAgentDescriptor {
    AcpAgentDescriptor(
      id: id,
      displayName: displayName,
      capabilities: ["fs.read", "terminal.spawn"],
      launchCommand: id,
      launchArgs: ["--acp"],
      envPassthrough: [],
      installHint: nil,
      doctorProbe: AcpDoctorProbe(command: id, args: ["--version"])
    )
  }
}
