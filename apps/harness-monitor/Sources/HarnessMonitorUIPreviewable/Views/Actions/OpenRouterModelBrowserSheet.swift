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
    NavigationStack {
      VStack(spacing: 0) {
        header
        Divider()
        providerChips
        Divider()
        listContent
      }
      .navigationBarBackButtonHidden(true)
      .searchable(text: $searchText, placement: .toolbar, prompt: "Search models")
    }
    .frame(minWidth: 520, minHeight: 480)
    .accessibilityIdentifier(HarnessMonitorAccessibility.openRouterModelBrowserSheet)
    .onChange(of: presentationInput, initial: true) { _, newInput in
      cachedPresentation = presentationWorker.compute(input: newInput)
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
        OpenRouterBrowserProviderChip(
          label: "All",
          isSelected: selectedProvider == nil
        ) {
          selectedProvider = nil
        }
        .equatable()
        ForEach(cachedPresentation.providers, id: \.self) { provider in
          OpenRouterBrowserProviderChip(
            label: provider,
            isSelected: selectedProvider == provider
          ) {
            selectedProvider = (selectedProvider == provider) ? nil : provider
          }
          .equatable()
        }
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingLG)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
    }
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
            OpenRouterModelBrowserRow(
              model: model,
              isPinned: usageSnapshot.isPinned(model.id),
              onTogglePin: { togglePin(model.id) },
              onSelect: { selectModel(model.id) }
            )
            .equatable()
          }
        }
        .listStyle(.inset)
        .accessibilityIdentifier(HarnessMonitorAccessibility.openRouterModelBrowserList)
      }
    }
  }

  private func togglePin(_ modelID: String) {
    usage.togglePin(modelID)
    usageSnapshot = usage.snapshot()
  }

  private func selectModel(_ modelID: String) {
    onSelect(modelID)
    dismiss()
  }
}
