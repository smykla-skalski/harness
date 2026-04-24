import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("RuntimeModel effort decoding")
struct RuntimeModelEffortTests {
  @Test("decodes snake_case effort metadata from the daemon")
  func decodesDaemonCatalog() throws {
    let json = #"""
      {
        "id": "gpt-5.5",
        "display_name": "GPT-5.5",
        "tier": "balanced",
        "effort_kind": "reasoning_effort",
        "effort_values": ["low", "medium", "high", "xhigh"]
      }
      """#
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let model = try decoder.decode(RuntimeModel.self, from: Data(json.utf8))
    #expect(model.id == "gpt-5.5")
    #expect(model.effortKind == .reasoningEffort)
    #expect(model.effortValues == ["low", "medium", "high", "xhigh"])
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

@Suite("AgentsWindowView effort helpers")
@MainActor
struct AgentsWindowViewEffortHelperTests {
  @Test("default effort prefers medium when offered")
  func defaultPrefersMedium() {
    let values = ["off", "low", "medium", "high"]
    #expect(AgentsWindowView.defaultEffortLevel(from: values) == "medium")
  }

  @Test("default effort falls back to the middle index when no medium")
  func defaultFallsBackToMiddle() {
    let values = ["off", "low", "high"]
    #expect(AgentsWindowView.defaultEffortLevel(from: values) == "low")
  }

  @Test("default effort on empty values returns empty string")
  func defaultOnEmptyValues() {
    #expect(AgentsWindowView.defaultEffortLevel(from: []).isEmpty)
  }

  @Test("effectiveModelId resolves custom tag to typed value")
  func customTagResolvesToTyped() {
    let resolved = AgentsWindowView.effectiveModelId(
      pickerValue: RuntimeCustomModel.tag,
      customValue: "  gpt-6-private  ",
      catalogDefault: "gpt-5.5"
    )
    #expect(resolved.id == "gpt-6-private")
    #expect(resolved.allowCustom)
  }

  @Test("effectiveModelId returns catalog default for empty picker")
  func emptyPickerFallsBackToDefault() {
    let resolved = AgentsWindowView.effectiveModelId(
      pickerValue: "",
      customValue: "",
      catalogDefault: "gpt-5.5"
    )
    #expect(resolved.id == "gpt-5.5")
    #expect(!resolved.allowCustom)
  }

  @Test("effortValues returns empty list when model lacks effort support")
  func nonReasoningModelHidesPicker() {
    let catalog = RuntimeModelCatalog(
      runtime: "test",
      models: [
        RuntimeModel(id: "flash-lite", displayName: "Flash-Lite", tier: .fast)
      ],
      default: "flash-lite",
      cheapestFastest: "flash-lite"
    )
    let values = AgentsWindowView.effortValues(catalog: catalog, selectedModelId: "flash-lite")
    #expect(values.isEmpty)
  }

  @Test("effortValues returns union for custom model tag")
  func customModelShowsAllEffortLevels() {
    let catalog = RuntimeModelCatalog(
      runtime: "test",
      models: [],
      default: "",
      cheapestFastest: ""
    )
    let values = AgentsWindowView.effortValues(
      catalog: catalog,
      selectedModelId: RuntimeCustomModel.tag
    )
    #expect(values == ["off", "low", "medium", "high", "xhigh"])
  }
}
