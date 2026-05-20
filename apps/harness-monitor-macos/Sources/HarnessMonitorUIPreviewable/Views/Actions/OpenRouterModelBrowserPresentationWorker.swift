import Foundation
import HarnessMonitorKit
import OSLog

struct OpenRouterModelBrowserPresentationInput: Equatable, Sendable {
  let models: [OpenRouterModelEntry]
  let searchText: String
  let selectedProvider: String?
}

struct OpenRouterModelBrowserPresentation: Equatable, Sendable {
  static let empty = Self(providers: [], filteredModels: [])

  let providers: [String]
  let filteredModels: [OpenRouterModelEntry]
}

@MainActor
final class OpenRouterModelBrowserPresentationWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

  private struct ModelsFingerprint: Equatable {
    let modelCount: Int
    let firstModelID: String?
    let lastModelID: String?
  }

  private struct FilterFingerprint: Equatable {
    let models: ModelsFingerprint
    let searchText: String
    let selectedProvider: String?
  }

  private var cachedModelsFingerprint: ModelsFingerprint?
  private var cachedProviders: [String] = []
  private var cachedSearchableEntries: [SearchableEntry] = []

  private var cachedFilterFingerprint: FilterFingerprint?
  private var cachedFilteredModels: [OpenRouterModelEntry] = []

  func compute(
    input: OpenRouterModelBrowserPresentationInput
  ) -> OpenRouterModelBrowserPresentation {
    let modelsFingerprint = ModelsFingerprint(
      modelCount: input.models.count,
      firstModelID: input.models.first?.id,
      lastModelID: input.models.last?.id
    )
    if modelsFingerprint != cachedModelsFingerprint {
      cachedModelsFingerprint = modelsFingerprint
      cachedProviders = Self.providers(from: input.models)
      cachedSearchableEntries = input.models.map(SearchableEntry.init(model:))
    }

    let filterFingerprint = FilterFingerprint(
      models: modelsFingerprint,
      searchText: input.searchText,
      selectedProvider: input.selectedProvider
    )
    if filterFingerprint == cachedFilterFingerprint {
      return OpenRouterModelBrowserPresentation(
        providers: cachedProviders,
        filteredModels: cachedFilteredModels
      )
    }

    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(
      "openrouter_model_browser.presentation.compute",
      id: signpostID,
      "models=\(input.models.count, privacy: .public)"
    )

    let needle = input.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let provider = input.selectedProvider
    var filtered: [OpenRouterModelEntry] = []
    filtered.reserveCapacity(cachedSearchableEntries.count)
    for entry in cachedSearchableEntries {
      if let provider, entry.provider != provider { continue }
      if !needle.isEmpty {
        if !entry.lowercasedID.contains(needle),
          entry.lowercasedName?.contains(needle) != true
        {
          continue
        }
      }
      filtered.append(entry.model)
    }
    cachedFilterFingerprint = filterFingerprint
    cachedFilteredModels = filtered

    Self.signposter.endInterval(
      "openrouter_model_browser.presentation.compute",
      interval,
      "filtered=\(filtered.count, privacy: .public)"
    )

    return OpenRouterModelBrowserPresentation(
      providers: cachedProviders,
      filteredModels: filtered
    )
  }

  private static func providers(from models: [OpenRouterModelEntry]) -> [String] {
    var seen: Set<String> = []
    seen.reserveCapacity(models.count)
    var ordered: [String] = []
    ordered.reserveCapacity(models.count)
    for model in models {
      let provider = model.provider
      if seen.insert(provider).inserted {
        ordered.append(provider)
      }
    }
    return ordered.sorted()
  }

  private struct SearchableEntry {
    let model: OpenRouterModelEntry
    let provider: String
    let lowercasedID: String
    let lowercasedName: String?

    init(model: OpenRouterModelEntry) {
      self.model = model
      provider = model.provider
      lowercasedID = model.id.lowercased()
      lowercasedName = model.name?.lowercased()
    }
  }
}

extension OpenRouterModelEntry {
  fileprivate var provider: String {
    id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? "other"
  }
}
