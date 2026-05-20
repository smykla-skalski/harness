import HarnessMonitorKit
import OSLog

struct OpenRouterModelPickerPresentationInput: Equatable, Sendable {
  let availableModels: [OpenRouterModelEntry]
  let usageSnapshot: OpenRouterModelUsageSnapshot
}

struct OpenRouterModelPickerInputFingerprint: Equatable, Sendable {
  let modelCount: Int
  let firstModelID: String?
  let lastModelID: String?
  let usageSnapshot: OpenRouterModelUsageSnapshot

  init(input: OpenRouterModelPickerPresentationInput) {
    modelCount = input.availableModels.count
    firstModelID = input.availableModels.first?.id
    lastModelID = input.availableModels.last?.id
    usageSnapshot = input.usageSnapshot
  }
}

struct OpenRouterModelPickerPresentation: Equatable, Sendable {
  static let empty = Self(sections: [], displayNamesByID: [:])

  let sections: [OpenRouterModelPickerMenuSection]
  fileprivate let displayNamesByID: [String: String]

  func displayName(for modelID: String) -> String? {
    displayNamesByID[modelID]
  }
}

struct OpenRouterModelPickerMenuSection: Equatable, Sendable {
  let title: String
  let entries: [OpenRouterModelPickerMenuEntry]
}

struct OpenRouterModelPickerMenuEntry: Equatable, Sendable {
  let id: String
  let displayName: String
}

@MainActor
final class OpenRouterModelPickerPresentationWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )
  private static let sectionCap = 5

  private var cachedFingerprint: OpenRouterModelPickerInputFingerprint?
  private var cachedOutput = OpenRouterModelPickerPresentation.empty

  func compute(
    input: OpenRouterModelPickerPresentationInput
  ) -> OpenRouterModelPickerPresentation {
    let fingerprint = OpenRouterModelPickerInputFingerprint(input: input)
    if fingerprint == cachedFingerprint {
      return cachedOutput
    }

    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(
      "openrouter_model_picker.presentation.compute",
      id: signpostID,
      "models=\(input.availableModels.count, privacy: .public)"
    )
    let output = Self.presentation(from: input)
    Self.signposter.endInterval(
      "openrouter_model_picker.presentation.compute",
      interval,
      "sections=\(output.sections.count, privacy: .public)"
    )

    cachedFingerprint = fingerprint
    cachedOutput = output
    return output
  }

  private static func presentation(
    from input: OpenRouterModelPickerPresentationInput
  ) -> OpenRouterModelPickerPresentation {
    let availableModels = input.availableModels
    var modelLookup: [String: OpenRouterModelEntry] = [:]
    modelLookup.reserveCapacity(availableModels.count)
    var displayNames: [String: String] = [:]
    displayNames.reserveCapacity(availableModels.count)
    for model in availableModels {
      modelLookup[model.id] = model
      displayNames[model.id] = model.name ?? model.id
    }

    var sectionList: [OpenRouterModelPickerMenuSection] = []
    sectionList.reserveCapacity(4)
    let usage = UsageBuckets(snapshot: input.usageSnapshot)
    let allowsFallback = availableModels.isEmpty

    if let pinned = makeSection(
      title: "Pinned",
      ids: usage.pinned,
      cap: nil,
      lookup: modelLookup,
      allowsFallbackEntries: allowsFallback
    ) {
      sectionList.append(pinned)
    }
    if let recent = makeSection(
      title: "Recently Used",
      ids: usage.recents,
      cap: Self.sectionCap,
      lookup: modelLookup,
      allowsFallbackEntries: allowsFallback
    ) {
      sectionList.append(recent)
    }
    if let frequent = makeSection(
      title: "Frequently Used",
      ids: usage.frequent,
      cap: Self.sectionCap,
      lookup: modelLookup,
      allowsFallbackEntries: allowsFallback
    ) {
      sectionList.append(frequent)
    }
    if sectionList.isEmpty,
      let popular = makeSection(
        title: "Popular",
        ids: OpenRouterPopularModels.modelIDs,
        cap: 10,
        lookup: modelLookup,
        allowsFallbackEntries: allowsFallback
      )
    {
      sectionList.append(popular)
    }

    return OpenRouterModelPickerPresentation(
      sections: sectionList,
      displayNamesByID: displayNames
    )
  }

  private static func makeSection(
    title: String,
    ids: [String],
    cap: Int?,
    lookup: [String: OpenRouterModelEntry],
    allowsFallbackEntries: Bool
  ) -> OpenRouterModelPickerMenuSection? {
    var resolved: [OpenRouterModelPickerMenuEntry] = []
    resolved.reserveCapacity(min(ids.count, cap ?? ids.count))
    let limit = cap ?? Int.max
    for id in ids {
      if resolved.count >= limit { break }
      if let model = lookup[id] {
        resolved.append(
          OpenRouterModelPickerMenuEntry(id: model.id, displayName: model.name ?? model.id)
        )
      } else if allowsFallbackEntries {
        resolved.append(OpenRouterModelPickerMenuEntry(id: id, displayName: id))
      }
    }
    return resolved.isEmpty
      ? nil
      : OpenRouterModelPickerMenuSection(title: title, entries: resolved)
  }

  private struct UsageBuckets {
    let pinned: [String]
    let recents: [String]
    let frequent: [String]

    init(snapshot: OpenRouterModelUsageSnapshot) {
      pinned = snapshot.pinned
      recents = snapshot.cachedRecentsExcludingPinned
      frequent = snapshot.cachedFrequentExcludingPinnedAndRecents
    }
  }
}
