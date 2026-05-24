import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("OpenRouter model presentation workers")
struct OpenRouterModelPresentationWorkerTests {
  @Test("picker worker builds usage sections from one snapshot")
  @MainActor
  func pickerWorkerBuildsUsageSections() {
    let models = [
      OpenRouterModelEntry(id: "openai/gpt-4.1", name: "GPT 4.1"),
      OpenRouterModelEntry(id: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4"),
      OpenRouterModelEntry(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
    ]
    let snapshot = OpenRouterModelUsageSnapshot(
      pinned: ["anthropic/claude-sonnet-4"],
      recents: ["anthropic/claude-sonnet-4", "openai/gpt-4.1"],
      frequencies: [
        "anthropic/claude-sonnet-4": 5,
        "google/gemini-2.5-pro": 4,
        "openai/gpt-4.1": 3,
      ]
    )

    let output = OpenRouterModelPickerPresentationWorker().compute(
      input: OpenRouterModelPickerPresentationInput(
        availableModels: models,
        usageSnapshot: snapshot
      )
    )

    #expect(output.sections.map(\.title) == ["Pinned", "Recently Used", "Frequently Used"])
    #expect(output.sections[0].entries.map(\.id) == ["anthropic/claude-sonnet-4"])
    #expect(output.sections[1].entries.map(\.id) == ["openai/gpt-4.1"])
    #expect(output.sections[2].entries.map(\.id) == ["google/gemini-2.5-pro"])
    #expect(output.displayName(for: "openai/gpt-4.1") == "GPT 4.1")
  }

  @Test("browser worker precomputes providers and filtered model rows")
  @MainActor
  func browserWorkerPrecomputesProvidersAndFilters() {
    let models = [
      OpenRouterModelEntry(id: "openai/gpt-4.1", name: "GPT 4.1"),
      OpenRouterModelEntry(id: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4"),
      OpenRouterModelEntry(id: "openai/o3", name: "o3"),
    ]

    let output = OpenRouterModelBrowserPresentationWorker().compute(
      input: OpenRouterModelBrowserPresentationInput(
        models: models,
        searchText: "o3",
        selectedProvider: "openai"
      )
    )

    #expect(output.providers == ["anthropic", "openai"])
    #expect(output.filteredModels.map(\.id) == ["openai/o3"])
  }

  @Test("browser worker reuses providers cache when only search changes")
  @MainActor
  func browserWorkerReusesProvidersCache() {
    let models = [
      OpenRouterModelEntry(id: "openai/gpt-4.1", name: "GPT 4.1"),
      OpenRouterModelEntry(id: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4"),
      OpenRouterModelEntry(id: "openai/o3", name: "o3"),
    ]
    let worker = OpenRouterModelBrowserPresentationWorker()

    let first = worker.compute(
      input: OpenRouterModelBrowserPresentationInput(
        models: models,
        searchText: "",
        selectedProvider: nil
      )
    )
    let second = worker.compute(
      input: OpenRouterModelBrowserPresentationInput(
        models: models,
        searchText: "claude",
        selectedProvider: nil
      )
    )

    #expect(first.providers == second.providers)
    #expect(second.filteredModels.map(\.id) == ["anthropic/claude-sonnet-4"])
  }
}
