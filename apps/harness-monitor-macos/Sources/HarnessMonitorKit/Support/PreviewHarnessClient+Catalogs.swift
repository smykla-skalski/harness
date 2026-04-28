import Foundation

extension PreviewHarnessClient {
  public func configuration() async throws -> MonitorConfiguration {
    MonitorConfiguration(
      personas: try await personas(),
      runtimeModels: try await runtimeModelCatalogs(),
      acpAgents: try await acpAgentDescriptors(),
      runtimeProbe: try await runtimeProbeResults()
    )
  }

  public func personas() async throws -> [AgentPersona] {
    [
      AgentPersona(
        identifier: "reviewer",
        name: "Reviewer",
        symbol: .sfSymbol(name: "checkmark.seal"),
        description: "Reviews code changes for correctness and style."
      ),
      AgentPersona(
        identifier: "architect",
        name: "Architect",
        symbol: .sfSymbol(name: "building.columns"),
        description: "Focuses on system design and architecture decisions."
      ),
    ]
  }

  public func runtimeModelCatalogs() async throws -> [RuntimeModelCatalog] {
    [
      RuntimeModelCatalog(
        runtime: "codex",
        models: [
          RuntimeModel(
            id: "gpt-5.3-codex-spark",
            displayName: "GPT-5.3 Codex Spark",
            tier: .fast,
            effortKind: .reasoningEffort,
            effortValues: ["low", "medium", "high", "xhigh"]
          ),
          RuntimeModel(
            id: "gpt-5.4-mini",
            displayName: "GPT-5.4 mini",
            tier: .fast,
            effortKind: .reasoningEffort,
            effortValues: ["low", "medium", "high", "xhigh"]
          ),
          RuntimeModel(
            id: "gpt-5.5",
            displayName: "GPT-5.5",
            tier: .balanced,
            effortKind: .reasoningEffort,
            effortValues: ["low", "medium", "high", "xhigh"]
          ),
          RuntimeModel(
            id: "gpt-5.4",
            displayName: "GPT-5.4",
            tier: .balanced,
            effortKind: .reasoningEffort,
            effortValues: ["low", "medium", "high", "xhigh"]
          ),
          RuntimeModel(
            id: "gpt-5.3-codex",
            displayName: "GPT-5.3 Codex",
            tier: .balanced,
            effortKind: .reasoningEffort,
            effortValues: ["low", "medium", "high", "xhigh"]
          ),
          RuntimeModel(
            id: "gpt-5.2",
            displayName: "GPT-5.2",
            tier: .balanced,
            effortKind: .reasoningEffort,
            effortValues: ["low", "medium", "high", "xhigh"]
          ),
        ],
        default: "gpt-5.5",
        cheapestFastest: "gpt-5.3-codex-spark"
      ),
      RuntimeModelCatalog(
        runtime: "claude",
        models: [
          RuntimeModel(id: "claude-haiku-4-5", displayName: "Haiku 4.5", tier: .fast),
          RuntimeModel(id: "claude-sonnet-4-6", displayName: "Sonnet 4.6", tier: .balanced),
        ],
        default: "claude-sonnet-4-6",
        cheapestFastest: "claude-haiku-4-5"
      ),
    ]
  }

  public func acpAgentDescriptors() async throws -> [AcpAgentDescriptor] {
    [
      AcpAgentDescriptor(
        id: "copilot",
        displayName: "GitHub Copilot",
        capabilities: ["fs.read", "fs.write", "terminal.spawn", "streaming", "multi-turn"],
        launchCommand: "copilot",
        launchArgs: ["--acp", "--stdio"],
        envPassthrough: ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"],
        modelCatalog: nil,
        installHint: "Install GitHub Copilot CLI and sign in.",
        doctorProbe: AcpDoctorProbe(command: "copilot", args: ["--version"])
      )
    ]
  }

  public func runtimeProbeResults() async throws -> AcpRuntimeProbeResponse {
    AcpRuntimeProbeResponse(
      probes: [
        AcpRuntimeProbe(
          agentId: "copilot",
          displayName: "GitHub Copilot",
          binaryPresent: true,
          authState: .unknown,
          version: "preview"
        )
      ],
      checkedAt: "2026-04-28T00:00:00Z"
    )
  }
}
