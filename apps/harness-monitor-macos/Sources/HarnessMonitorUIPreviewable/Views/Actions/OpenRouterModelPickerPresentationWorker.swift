import HarnessMonitorKit
import OSLog

struct OpenRouterModelPickerPresentationInput: Equatable, Sendable {
  let availableModels: [OpenRouterModelEntry]
  let usageSnapshot: OpenRouterModelUsageSnapshot
}

struct OpenRouterModelPickerPresentation: Equatable, Sendable {
  static let empty = Self(sections: [], displayNamesByID: [:])

  let sections: [OpenRouterModelPickerMenuSection]
  fileprivate let displayNamesByID: [String: String]

  fileprivate init(
    sections: [OpenRouterModelPickerMenuSection],
    displayNamesByID: [String: String]
  ) {
    self.sections = sections
    self.displayNamesByID = displayNamesByID
  }

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

actor OpenRouterModelPickerPresentationWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )
  private static let sectionCap = 5

  private var cachedInput: OpenRouterModelPickerPresentationInput?
  private var cachedOutput = OpenRouterModelPickerPresentation.empty

  func compute(
    input: OpenRouterModelPickerPresentationInput
  ) -> OpenRouterModelPickerPresentation {
    guard input != cachedInput else {
      return cachedOutput
    }

    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(
      "openrouter_model_picker.presentation.compute",
      id: signpostID,
      "models=\(input.availableModels.count, privacy: .public)"
    )
    defer {
      Self.signposter.endInterval(
        "openrouter_model_picker.presentation.compute",
        interval,
        "sections=\(self.cachedOutput.sections.count, privacy: .public)"
      )
    }

    cachedInput = input
    cachedOutput = Self.presentation(from: input)
    return cachedOutput
  }

  func waitForIdle() async {}

  private static func presentation(
    from input: OpenRouterModelPickerPresentationInput
  ) -> OpenRouterModelPickerPresentation {
    let modelLookup = Dictionary(uniqueKeysWithValues: input.availableModels.map { ($0.id, $0) })
    var sectionList: [OpenRouterModelPickerMenuSection] = []
    let usage = UsageBuckets(snapshot: input.usageSnapshot)

    if let pinned = makeSection(
      title: "Pinned",
      ids: usage.pinned,
      cap: nil,
      lookup: modelLookup,
      allowsFallbackEntries: input.availableModels.isEmpty
    ) {
      sectionList.append(pinned)
    }
    if let recent = makeSection(
      title: "Recently Used",
      ids: usage.recents,
      cap: Self.sectionCap,
      lookup: modelLookup,
      allowsFallbackEntries: input.availableModels.isEmpty
    ) {
      sectionList.append(recent)
    }
    if let frequent = makeSection(
      title: "Frequently Used",
      ids: usage.frequent,
      cap: Self.sectionCap,
      lookup: modelLookup,
      allowsFallbackEntries: input.availableModels.isEmpty
    ) {
      sectionList.append(frequent)
    }
    if sectionList.isEmpty,
      let popular = makeSection(
        title: "Popular",
        ids: OpenRouterPopularModels.modelIDs,
        cap: 10,
        lookup: modelLookup,
        allowsFallbackEntries: input.availableModels.isEmpty
      )
    {
      sectionList.append(popular)
    }

    return OpenRouterModelPickerPresentation(
      sections: sectionList,
      displayNamesByID: Dictionary(
        uniqueKeysWithValues: input.availableModels.map { ($0.id, $0.name ?? $0.id) }
      )
    )
  }

  private static func makeSection(
    title: String,
    ids: [String],
    cap: Int?,
    lookup: [String: OpenRouterModelEntry],
    allowsFallbackEntries: Bool
  ) -> OpenRouterModelPickerMenuSection? {
    let resolved =
      ids
      .compactMap { id -> OpenRouterModelPickerMenuEntry? in
        if let model = lookup[id] {
          return OpenRouterModelPickerMenuEntry(
            id: model.id,
            displayName: model.name ?? model.id
          )
        }
        if allowsFallbackEntries {
          return OpenRouterModelPickerMenuEntry(id: id, displayName: id)
        }
        return nil
      }
    let trimmed: [OpenRouterModelPickerMenuEntry]
    if let cap, cap > 0 {
      trimmed = Array(resolved.prefix(cap))
    } else {
      trimmed = resolved
    }
    return trimmed.isEmpty
      ? nil
      : OpenRouterModelPickerMenuSection(title: title, entries: trimmed)
  }

  private struct UsageBuckets {
    let pinned: [String]
    let recents: [String]
    let frequent: [String]

    init(snapshot: OpenRouterModelUsageSnapshot) {
      pinned = snapshot.pinned
      let pinnedSet = Set(pinned)
      recents = snapshot.recentModels().filter { !pinnedSet.contains($0) }
      let recentSet = Set(recents)
      frequent = snapshot.frequentModels()
        .filter { !pinnedSet.contains($0) && !recentSet.contains($0) }
    }
  }
}
