import HarnessMonitorKit
import SwiftUI

@MainActor
struct OpenRouterModelPicker: View {
  let availableModels: [OpenRouterModelEntry]
  let usage: OpenRouterModelUsageStore
  @Binding var selectedModelID: String
  @Binding var useCustomModel: Bool
  let onBrowseAll: () -> Void

  private static let sectionCap = 5

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      pickerRow
      browseLink
    }
  }

  private var pickerRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      browseIconButton
      pickerControl
    }
  }

  private var pickerControl: some View {
    Picker(menuTitle, selection: $selectedModelID) {
      pickerContent
    }
    .pickerStyle(.menu)
    .harnessNativeFormControl()
    .onChange(of: selectedModelID) { _, newValue in
      useCustomModel = newValue == Self.customSentinel
    }
  }

  @ViewBuilder
  private var pickerContent: some View {
    ForEach(sections, id: \.title) { section in
      Section(section.title) {
        ForEach(section.entries, id: \.id) { entry in
          Text(entry.displayName).tag(entry.id)
        }
      }
    }
    Section {
      Text("Custom…").tag(Self.customSentinel)
    }
  }

  static let customSentinel = "__custom__"

  private var browseIconButton: some View {
    Button {
      onBrowseAll()
    } label: {
      Image(systemName: "rectangle.grid.2x2")
        .scaledFont(.body)
    }
    .buttonStyle(.bordered)
    .controlSize(.regular)
    .disabled(availableModels.isEmpty)
    .help(browseLabel)
    .accessibilityLabel(browseLabel)
  }

  private var browseLink: some View {
    Button {
      onBrowseAll()
    } label: {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: "magnifyingglass")
        Text(browseLabel)
      }
      .scaledFont(.caption)
    }
    .buttonStyle(.link)
    .disabled(availableModels.isEmpty)
  }

  private var browseLabel: String {
    let count = availableModels.count
    if count == 0 { return "Browse models…" }
    return "Browse all \(count) models…"
  }

  private var menuTitle: String {
    if useCustomModel { return "Custom model" }
    if let entry = availableModels.first(where: { $0.id == selectedModelID }) {
      return entry.name ?? entry.id
    }
    return selectedModelID
  }

  private var sections: [MenuSection] {
    let usageSnapshot = UsageSnapshot(usage: usage)
    let modelLookup = Dictionary(uniqueKeysWithValues: availableModels.map { ($0.id, $0) })
    var sectionList: [MenuSection] = []
    if let pinned = makeSection(
      title: "Pinned",
      ids: usageSnapshot.pinned,
      cap: nil,
      lookup: modelLookup
    ) {
      sectionList.append(pinned)
    }
    if let recent = makeSection(
      title: "Recently Used",
      ids: usageSnapshot.recents,
      cap: Self.sectionCap,
      lookup: modelLookup
    ) {
      sectionList.append(recent)
    }
    if let frequent = makeSection(
      title: "Frequently Used",
      ids: usageSnapshot.frequent,
      cap: Self.sectionCap,
      lookup: modelLookup
    ) {
      sectionList.append(frequent)
    }
    if sectionList.isEmpty {
      if let popular = makeSection(
        title: "Popular",
        ids: OpenRouterPopularModels.modelIDs,
        cap: 10,
        lookup: modelLookup
      ) {
        sectionList.append(popular)
      }
    }
    return sectionList
  }

  private func makeSection(
    title: String,
    ids: [String],
    cap: Int?,
    lookup: [String: OpenRouterModelEntry]
  ) -> MenuSection? {
    let resolved = ids
      .compactMap { id -> Entry? in
        if let model = lookup[id] {
          return Entry(id: model.id, displayName: model.name ?? model.id)
        }
        if availableModels.isEmpty {
          return Entry(id: id, displayName: id)
        }
        return nil
      }
    let trimmed: [Entry]
    if let cap, cap > 0 {
      trimmed = Array(resolved.prefix(cap))
    } else {
      trimmed = resolved
    }
    return trimmed.isEmpty ? nil : MenuSection(title: title, entries: trimmed)
  }

  private struct MenuSection {
    let title: String
    let entries: [Entry]
  }

  private struct Entry {
    let id: String
    let displayName: String
  }

  private struct UsageSnapshot {
    let pinned: [String]
    let recents: [String]
    let frequent: [String]

    init(usage: OpenRouterModelUsageStore) {
      pinned = usage.pinnedModels()
      let pinnedSet = Set(pinned)
      recents = usage.recentModels().filter { !pinnedSet.contains($0) }
      let recentSet = Set(recents)
      frequent = usage.frequentModels().filter { !pinnedSet.contains($0) && !recentSet.contains($0) }
    }
  }
}
