import HarnessMonitorKit
import SwiftUI

@MainActor
public struct OpenRouterModelBrowserSheet: View {
  public let models: [OpenRouterModelEntry]
  public let usage: OpenRouterModelUsageStore
  public let onSelect: (String) -> Void

  @Environment(\.dismiss)
  private var dismiss
  @Binding private var usageSnapshot: OpenRouterModelUsageSnapshot
  @State private var searchText: String = ""
  @State private var selectedProvider: String?
  @State private var presentationWorker = OpenRouterModelBrowserPresentationWorker()
  @State private var cachedPresentation = OpenRouterModelBrowserPresentation.empty
  @State private var presentationGeneration: UInt64 = 0

  public init(
    models: [OpenRouterModelEntry],
    usage: OpenRouterModelUsageStore,
    usageSnapshot: Binding<OpenRouterModelUsageSnapshot>,
    onSelect: @escaping (String) -> Void
  ) {
    self.models = models
    self.usage = usage
    _usageSnapshot = usageSnapshot
    self.onSelect = onSelect
  }

  private var presentationInput: OpenRouterModelBrowserPresentationInput {
    OpenRouterModelBrowserPresentationInput(
      models: models,
      searchText: searchText,
      selectedProvider: selectedProvider
    )
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
    .task(id: presentationInput) {
      await rebuildPresentation(input: presentationInput)
    }
  }

  private var header: some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("Browse OpenRouter Models")
          .scaledFont(.system(.title3, design: .rounded, weight: .bold))
        Text("\(cachedPresentation.filteredModels.count) of \(models.count) models")
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
        ForEach(cachedPresentation.providers, id: \.self) { provider in
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
              isSelected
                ? HarnessMonitorTheme.accent : HarnessMonitorTheme.secondaryInk.opacity(0.3),
              lineWidth: 0.5
            )
        )
    }
    .harnessPlainButtonStyle()
  }

  private var listContent: some View {
    let filteredModels = cachedPresentation.filteredModels
    return Group {
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
    let isPinned = usageSnapshot.isPinned(modelID)
    return Button {
      usage.togglePin(modelID)
      usageSnapshot = usage.snapshot()
    } label: {
      Image(systemName: isPinned ? "pin.fill" : "pin")
        .foregroundStyle(isPinned ? HarnessMonitorTheme.accent : HarnessMonitorTheme.secondaryInk)
    }
    .harnessPlainButtonStyle()
    .help(isPinned ? "Unpin model" : "Pin model")
    .accessibilityLabel(isPinned ? "Unpin \(modelID)" : "Pin \(modelID)")
  }

  @MainActor
  private func rebuildPresentation(input: OpenRouterModelBrowserPresentationInput) async {
    presentationGeneration &+= 1
    let generation = presentationGeneration
    let presentation = await presentationWorker.compute(input: input)
    guard !Task.isCancelled, presentationGeneration == generation else {
      return
    }
    if cachedPresentation != presentation {
      cachedPresentation = presentation
    }
  }
}
