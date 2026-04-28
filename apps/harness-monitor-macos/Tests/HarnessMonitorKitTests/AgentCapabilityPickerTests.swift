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
      probe: nil,
      installHint: nil
    )

    #expect(option.normalizedSelection(for: .tui(.codex)) == .tui(.gemini))
    #expect(option.transportChoice(for: .tui(.codex)).id == .tui(.gemini))
    #expect(option.normalizedSelection(for: .acp("gemini")) == .acp("gemini"))
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
      probe: AcpRuntimeProbe(
        agentId: "gemini",
        displayName: "Gemini CLI",
        binaryPresent: false,
        authState: .unavailable
      ),
      installHint: "Install Gemini"
    )

    #expect(option.isEnabled)
    #expect(option.statusText == "Ready")
    #expect(option.isEnabled(option.transportChoice(for: .tui(.gemini))))
    #expect(!option.isEnabled(option.transportChoice(for: .acp("gemini"))))
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
