import HarnessMonitorKit
import SwiftUI

@MainActor
public struct OpenRouterModelBrowserSheet: View {
  public let models: [OpenRouterModelEntry]
  public let usage: OpenRouterModelUsageStore
  public let onSelect: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var searchText: String = ""
  @State private var selectedProvider: String? = nil
  @State private var pinTick: Int = 0

  public init(
    models: [OpenRouterModelEntry],
    usage: OpenRouterModelUsageStore,
    onSelect: @escaping (String) -> Void
  ) {
    self.models = models
    self.usage = usage
    self.onSelect = onSelect
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      providerChips
      Divider()
      listContent
    }
    .frame(minWidth: 520, minHeight: 480)
    .accessibilityIdentifier(HarnessMonitorAccessibility.openRouterModelBrowserSheet)
  }

  private var header: some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("Browse OpenRouter Models")
          .scaledFont(.system(.title3, design: .rounded, weight: .bold))
        Text("\(filteredModels.count) of \(models.count) models")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Spacer()
      Button("Close") { dismiss() }
        .keyboardShortcut(.cancelAction)
    }
    .padding(HarnessMonitorTheme.spacingLG)
  }

  private var providerChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        chip(label: "All", isSelected: selectedProvider == nil) {
          selectedProvider = nil
        }
        ForEach(providers, id: \.self) { provider in
          chip(label: provider, isSelected: selectedProvider == provider) {
            selectedProvider = (selectedProvider == provider) ? nil : provider
          }
        }
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingLG)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
    }
  }

  private func chip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(label)
        .scaledFont(.caption)
        .padding(.horizontal, HarnessMonitorTheme.spacingSM)
        .padding(.vertical, 4)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? HarnessMonitorTheme.accent.opacity(0.18) : Color.clear)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(
              isSelected ? HarnessMonitorTheme.accent : HarnessMonitorTheme.secondaryInk.opacity(0.3),
              lineWidth: 0.5
            )
        )
    }
    .buttonStyle(.plain)
  }

  private var listContent: some View {
    Group {
      if filteredModels.isEmpty {
        VStack(spacing: HarnessMonitorTheme.spacingSM) {
          Image(systemName: "magnifyingglass")
            .scaledFont(.title2)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Text("No models match the current filter.")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          ForEach(filteredModels, id: \.id) { model in
            modelRow(model)
          }
        }
        .listStyle(.inset)
        .accessibilityIdentifier(HarnessMonitorAccessibility.openRouterModelBrowserList)
      }
    }
    .searchable(text: $searchText, placement: .toolbar, prompt: "Search models")
  }

  private func modelRow(_ model: OpenRouterModelEntry) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: 2) {
        Text(model.name ?? model.id)
          .scaledFont(.body.weight(.semibold))
        Text(model.id)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        if let context = model.contextLength {
          Text("Context: \(context.formatted()) tokens")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      Spacer()
      pinButton(for: model.id)
      Button("Select") {
        onSelect(model.id)
        dismiss()
      }
      .controlSize(.small)
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }

  private func pinButton(for modelID: String) -> some View {
    let isPinned = usage.isPinned(modelID)
    return Button {
      usage.togglePin(modelID)
      pinTick &+= 1
    } label: {
      Image(systemName: isPinned ? "pin.fill" : "pin")
        .foregroundStyle(isPinned ? HarnessMonitorTheme.accent : HarnessMonitorTheme.secondaryInk)
    }
    .buttonStyle(.plain)
    .help(isPinned ? "Unpin model" : "Pin model")
    .accessibilityLabel(isPinned ? "Unpin \(modelID)" : "Pin \(modelID)")
  }

  private var providers: [String] {
    var seen: Set<String> = []
    var ordered: [String] = []
    for model in models {
      let provider = model.id.split(separator: "/").first.map(String.init) ?? "other"
      if seen.insert(provider).inserted {
        ordered.append(provider)
      }
    }
    return ordered.sorted()
  }

  private var filteredModels: [OpenRouterModelEntry] {
    let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return models.filter { model in
      if let provider = selectedProvider {
        let modelProvider = model.id.split(separator: "/").first.map(String.init) ?? "other"
        if modelProvider != provider { return false }
      }
      if needle.isEmpty { return true }
      if model.id.lowercased().contains(needle) { return true }
      if let name = model.name?.lowercased(), name.contains(needle) { return true }
      return false
    }
  }
}
