import Foundation

extension PreviewHarnessClient {
  public static let previewPersonas: [AgentPersona] = [
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

  public static let previewRuntimeModelCatalogs: [RuntimeModelCatalog] = [
    codexRuntimeModelCatalog(),
    claudeRuntimeModelCatalog(),
    geminiRuntimeModelCatalog(),
    copilotRuntimeModelCatalog(),
  ]

  public static let previewAcpAgentDescriptors: [AcpAgentDescriptor] = [
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
    ),
    AcpAgentDescriptor(
      id: "gemini",
      displayName: "Gemini CLI",
      capabilities: [
        "fs.read",
        "fs.write",
        "terminal.spawn",
        "streaming",
        "multi-turn",
        "requires-network",
      ],
      launchCommand: "gemini",
      launchArgs: ["--acp"],
      envPassthrough: [
        "GEMINI_API_KEY",
        "GOOGLE_API_KEY",
        "GOOGLE_CLOUD_PROJECT",
        "GOOGLE_CLOUD_LOCATION",
        "GOOGLE_APPLICATION_CREDENTIALS",
        "GOOGLE_GENAI_USE_VERTEXAI",
        "GOOGLE_GENAI_API_VERSION",
        "GOOGLE_GEMINI_BASE_URL",
        "GOOGLE_VERTEX_BASE_URL",
        "GEMINI_MODEL",
        "GEMINI_CLI_HOME",
        "GEMINI_CLI_TRUST_WORKSPACE",
      ],
      modelCatalog: nil,
      installHint: "Install an ACP-capable Gemini CLI and authenticate.",
      doctorProbe: AcpDoctorProbe(command: "gemini", args: ["--version"])
    ),
  ]

  public static func previewRuntimeProbeResults(
    missingBinaryAgentIDs: Set<String> = []
  ) -> AcpRuntimeProbeResponse {
    AcpRuntimeProbeResponse(
      probes: [
        AcpRuntimeProbe(
          agentId: "copilot",
          displayName: "GitHub Copilot",
          binaryPresent: !missingBinaryAgentIDs.contains("copilot"),
          authState: .unknown,
          version: "preview",
        ),
        AcpRuntimeProbe(
          agentId: "gemini",
          displayName: "Gemini CLI",
          binaryPresent: !missingBinaryAgentIDs.contains("gemini"),
          authState: .unknown,
          version: "preview"
        ),
      ],
      checkedAt: "2026-04-28T00:00:00Z"
    )
  }

  public func configuration() async throws -> MonitorConfiguration {
    MonitorConfiguration(
      personas: try await personas(),
      runtimeModels: try await runtimeModelCatalogs(),
      acpAgents: try await acpAgentDescriptors(),
      runtimeProbe: try await runtimeProbeResults()
    )
  }

  public func personas() async throws -> [AgentPersona] {
    Self.previewPersonas
  }

  public func runtimeModelCatalogs() async throws -> [RuntimeModelCatalog] {
    Self.previewRuntimeModelCatalogs
  }

  public func acpAgentDescriptors() async throws -> [AcpAgentDescriptor] {
    Self.previewAcpAgentDescriptors
  }

  public func runtimeProbeResults() async throws -> AcpRuntimeProbeResponse {
    let missingBinaryAgentIDs = Set(
      ProcessInfo.processInfo.environment["HARNESS_MONITOR_PREVIEW_ACP_MISSING_BINARIES"]?
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty } ?? []
    )
    return Self.previewRuntimeProbeResults(missingBinaryAgentIDs: missingBinaryAgentIDs)
  }

  private static func codexRuntimeModelCatalog() -> RuntimeModelCatalog {
    RuntimeModelCatalog(
      runtime: "codex",
      models: [
        reasoningModel("gpt-5.3-codex-spark", displayName: "GPT-5.3 Codex Spark", tier: .fast),
        reasoningModel("gpt-5.4-mini", displayName: "GPT-5.4 mini", tier: .fast),
        reasoningModel("gpt-5.5", displayName: "GPT-5.5", tier: .balanced),
        reasoningModel("gpt-5.4", displayName: "GPT-5.4", tier: .balanced),
        reasoningModel("gpt-5.3-codex", displayName: "GPT-5.3 Codex", tier: .balanced),
        reasoningModel("gpt-5.2", displayName: "GPT-5.2", tier: .balanced),
      ],
      default: "gpt-5.5",
      cheapestFastest: "gpt-5.3-codex-spark"
    )
  }

  private static func claudeRuntimeModelCatalog() -> RuntimeModelCatalog {
    RuntimeModelCatalog(
      runtime: "claude",
      models: [
        RuntimeModel(id: "claude-haiku-4-5", displayName: "Haiku 4.5", tier: .fast),
        RuntimeModel(id: "claude-sonnet-4-6", displayName: "Sonnet 4.6", tier: .balanced),
      ],
      default: "claude-sonnet-4-6",
      cheapestFastest: "claude-haiku-4-5"
    )
  }

  private static func geminiRuntimeModelCatalog() -> RuntimeModelCatalog {
    RuntimeModelCatalog(
      runtime: "gemini",
      models: [
        RuntimeModel(
          id: "gemini-2.5-flash-lite",
          displayName: "Gemini 2.5 Flash-Lite",
          tier: .fast
        ),
        RuntimeModel(
          id: "gemini-2.5-pro",
          displayName: "Gemini 2.5 Pro",
          tier: .balanced,
          effortKind: .reasoningEffort,
          effortValues: ["low", "medium", "high"]
        ),
      ],
      default: "gemini-2.5-pro",
      cheapestFastest: "gemini-2.5-flash-lite"
    )
  }

  private static func copilotRuntimeModelCatalog() -> RuntimeModelCatalog {
    RuntimeModelCatalog(
      runtime: "copilot",
      models: [
        reasoningModel("gpt-5.4-mini", displayName: "GPT-5.4 mini", tier: .fast),
        reasoningModel("gpt-5.5", displayName: "GPT-5.5", tier: .balanced),
      ],
      default: "gpt-5.5",
      cheapestFastest: "gpt-5.4-mini"
    )
  }

  private static func reasoningModel(
    _ id: String,
    displayName: String,
    tier: RuntimeModelTier
  ) -> RuntimeModel {
    RuntimeModel(
      id: id,
      displayName: displayName,
      tier: tier,
      effortKind: .reasoningEffort,
      effortValues: ["low", "medium", "high", "xhigh"]
    )
  }
}
