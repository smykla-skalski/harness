import Foundation

extension PreviewHarnessClient {
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
}
