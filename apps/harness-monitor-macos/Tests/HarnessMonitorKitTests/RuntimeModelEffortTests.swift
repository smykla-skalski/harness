import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("RuntimeModel effort decoding")
struct RuntimeModelEffortTests {
  @Test("decodes snake_case effort metadata from the daemon")
  func decodesDaemonCatalog() throws {
    let json = #"""
      {
        "id": "gpt-5-codex",
        "display_name": "GPT-5 Codex",
        "tier": "balanced",
        "effort_kind": "reasoning_effort",
        "effort_values": ["minimal", "low", "medium", "high"]
      }
      """#
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let model = try decoder.decode(RuntimeModel.self, from: Data(json.utf8))
    #expect(model.id == "gpt-5-codex")
    #expect(model.effortKind == .reasoningEffort)
    #expect(model.effortValues == ["minimal", "low", "medium", "high"])
    #expect(model.supportsEffort)
  }

  @Test("missing effort metadata falls back to no support")
  func decodesLegacyEntry() throws {
    let json = #"""
      { "id": "x", "display_name": "X", "tier": "fast" }
      """#
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let model = try decoder.decode(RuntimeModel.self, from: Data(json.utf8))
    #expect(model.effortKind == .none)
    #expect(model.effortValues.isEmpty)
    #expect(!model.supportsEffort)
  }

  @Test("thinking budget kind reports support")
  func thinkingBudgetSupports() {
    let model = RuntimeModel(
      id: "claude-sonnet-4-6",
      displayName: "Sonnet 4.6",
      tier: .balanced,
      effortKind: .thinkingBudget,
      effortValues: ["off", "low", "medium", "high"]
    )
    #expect(model.supportsEffort)
  }
}
