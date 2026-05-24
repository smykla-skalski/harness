import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension AgentCapabilityPickerTests {
  @Test("missing selected ACP descriptor falls back to runtime TUI choice")
  func missingSelectedAcpDescriptorFallsBackToRuntime() {
    let options = AgentCapabilityCatalog.options(
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

    let normalizedSelection = AgentCapabilityCatalog.normalizedLaunchSelection(
      options: options,
      selection: .acp("removed-agent"),
      fallbackRuntime: .gemini
    )

    #expect(normalizedSelection == .tui(.gemini))
  }

  @Test("first launch selection prefers the first ACP-ready provider")
  func firstLaunchSelectionPrefersFirstAcpReadyProvider() {
    let options = AgentCapabilityCatalog.options(
      acpAgents: [
        descriptor(id: "copilot", displayName: "GitHub Copilot")
      ],
      runtimeProbeResults: AcpRuntimeProbeResponse(
        probes: [
          AcpRuntimeProbe(
            agentId: "copilot",
            displayName: "GitHub Copilot",
            binaryPresent: true,
            authState: .ready
          )
        ],
        checkedAt: "2026-04-28T22:15:00Z"
      )
    )

    #expect(
      AgentCapabilityCatalog.firstProviderLaunchSelection(options: options) == .acp("copilot"))
  }

  @Test("first launch selection prefers Codex ACP when the managed adapter is ready")
  func firstLaunchSelectionPrefersCodexAcpWhenReady() {
    let options = AgentCapabilityCatalog.options(
      acpAgents: [
        descriptor(id: "codex", displayName: "Codex")
      ],
      runtimeProbeResults: AcpRuntimeProbeResponse(
        probes: [
          AcpRuntimeProbe(
            agentId: "codex",
            displayName: "Codex",
            binaryPresent: true,
            authState: .ready
          )
        ],
        checkedAt: "2026-05-11T18:45:00Z"
      )
    )

    #expect(
      AgentCapabilityCatalog.firstProviderLaunchSelection(options: options) == .acp("codex"))
  }

  @Test("first launch selection skips ACP providers excluded from the initial default")
  func firstLaunchSelectionSkipsExcludedInitialDefaultProviders() {
    let options = AgentCapabilityCatalog.options(
      acpAgents: [
        descriptor(
          id: "claude",
          displayName: "Claude Code",
          excludedFromInitialDefault: true
        ),
        descriptor(id: "gemini", displayName: "Gemini CLI"),
      ],
      runtimeProbeResults: AcpRuntimeProbeResponse(
        probes: [
          AcpRuntimeProbe(
            agentId: "claude",
            displayName: "Claude Code",
            binaryPresent: true,
            authState: .ready
          ),
          AcpRuntimeProbe(
            agentId: "gemini",
            displayName: "Gemini CLI",
            binaryPresent: true,
            authState: .ready
          ),
        ],
        checkedAt: "2026-05-11T12:00:00Z"
      )
    )

    #expect(
      AgentCapabilityCatalog.firstProviderLaunchSelection(options: options) == .acp("gemini"))
  }

  @Test("stored provider id defaults to ACP when that provider supports ACP")
  func storedProviderDefaultsToAcpWhenAvailable() {
    let options = AgentCapabilityCatalog.options(
      acpAgents: [
        descriptor(id: "gemini", displayName: "Gemini CLI")
      ],
      runtimeProbeResults: AcpRuntimeProbeResponse(
        probes: [
          AcpRuntimeProbe(
            agentId: "gemini",
            displayName: "Gemini CLI",
            binaryPresent: true,
            authState: .ready
          )
        ],
        checkedAt: "2026-04-28T22:20:00Z"
      )
    )

    #expect(
      AgentCapabilityCatalog.defaultLaunchSelection(
        providerID: "gemini",
        options: options,
        fallback: .tui(.codex)
      ) == .acp("gemini")
    )
  }

  @Test("stored provider id falls back to TUI when ACP is unavailable")
  func storedProviderFallsBackToTuiWhenAcpUnavailable() {
    let options = AgentCapabilityCatalog.options(
      acpAgents: [
        descriptor(id: "gemini", displayName: "Gemini CLI")
      ],
      runtimeProbeResults: AcpRuntimeProbeResponse(
        probes: [
          AcpRuntimeProbe(
            agentId: "gemini",
            displayName: "Gemini CLI",
            binaryPresent: false,
            authState: .unavailable
          )
        ],
        checkedAt: "2026-04-28T22:25:00Z"
      )
    )

    #expect(
      AgentCapabilityCatalog.defaultLaunchSelection(
        providerID: "gemini",
        options: options,
        fallback: .tui(.codex)
      ) == .tui(.gemini)
    )
  }

  @Test("stored provider id defaults to ACP after sandbox bridge becomes ready")
  func storedProviderDefaultsToAcpAfterBridgeBecomesReady() {
    let descriptors = [
      descriptor(id: "gemini", displayName: "Gemini CLI")
    ]
    let probes = AcpRuntimeProbeResponse(
      probes: [
        AcpRuntimeProbe(
          agentId: "gemini",
          displayName: "Gemini CLI",
          binaryPresent: true,
          authState: .ready
        )
      ],
      checkedAt: "2026-04-28T22:30:00Z"
    )
    let waitingOptions = AgentCapabilityCatalog.options(
      acpAgents: descriptors,
      runtimeProbeResults: probes,
      sandboxed: true,
      acpHostBridgeReady: false
    )
    let readyOptions = AgentCapabilityCatalog.options(
      acpAgents: descriptors,
      runtimeProbeResults: probes,
      sandboxed: true,
      acpHostBridgeReady: true
    )

    #expect(
      AgentCapabilityCatalog.defaultLaunchSelection(
        providerID: "gemini",
        options: waitingOptions,
        fallback: .tui(.codex)
      ) == .tui(.gemini)
    )
    #expect(
      AgentCapabilityCatalog.defaultLaunchSelection(
        providerID: "gemini",
        options: readyOptions,
        fallback: .tui(.gemini)
      ) == .acp("gemini")
    )
  }
}
