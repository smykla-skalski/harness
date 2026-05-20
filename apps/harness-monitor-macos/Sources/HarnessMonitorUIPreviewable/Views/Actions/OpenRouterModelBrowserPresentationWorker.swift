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

actor OpenRouterModelBrowserPresentationWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

  private var cachedInput: OpenRouterModelBrowserPresentationInput?
  private var cachedOutput = OpenRouterModelBrowserPresentation.empty

  func compute(
    input: OpenRouterModelBrowserPresentationInput
  ) -> OpenRouterModelBrowserPresentation {
    guard input != cachedInput else {
      return cachedOutput
    }

    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(
      "openrouter_model_browser.presentation.compute",
      id: signpostID,
      "models=\(input.models.count, privacy: .public)"
    )
    defer {
      Self.signposter.endInterval(
        "openrouter_model_browser.presentation.compute",
        interval,
        "filtered=\(self.cachedOutput.filteredModels.count, privacy: .public)"
      )
    }

    cachedInput = input
    cachedOutput = Self.presentation(from: input)
    return cachedOutput
  }

  func waitForIdle() async {}

  private static func presentation(
    from input: OpenRouterModelBrowserPresentationInput
  ) -> OpenRouterModelBrowserPresentation {
    let providers = providers(from: input.models)
    let needle = input.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let filteredModels = input.models.filter { model in
      if let provider = input.selectedProvider, model.provider != provider {
        return false
      }
      if needle.isEmpty {
        return true
      }
      if model.id.localizedCaseInsensitiveContains(needle) {
        return true
      }
      return model.name?.localizedCaseInsensitiveContains(needle) == true
    }
    return OpenRouterModelBrowserPresentation(
      providers: providers,
      filteredModels: filteredModels
    )
  }

  private static func providers(from models: [OpenRouterModelEntry]) -> [String] {
    var seen: Set<String> = []
    var ordered: [String] = []
    for model in models {
      let provider = model.provider
      if seen.insert(provider).inserted {
        ordered.append(provider)
      }
    }
    return ordered.sorted()
  }
}

extension OpenRouterModelEntry {
  fileprivate var provider: String {
    id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? "other"
  }
}
