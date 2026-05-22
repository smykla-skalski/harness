import HarnessMonitorKit
import SwiftUI

@MainActor
struct OpenRouterModelPicker: View {
  let availableModels: [OpenRouterModelEntry]
  let usageSnapshot: OpenRouterModelUsageSnapshot
  @Binding var selectedModelID: String
  @Binding var useCustomModel: Bool
  let onBrowseAll: () -> Void

  @State private var presentationWorker = OpenRouterModelPickerPresentationWorker()
  @State private var cachedPresentation = OpenRouterModelPickerPresentation.empty

  private var presentationFingerprint: OpenRouterModelPickerInputFingerprint {
    OpenRouterModelPickerInputFingerprint(input: presentationInput)
  }

  private var presentationInput: OpenRouterModelPickerPresentationInput {
    OpenRouterModelPickerPresentationInput(
      availableModels: availableModels,
      usageSnapshot: usageSnapshot
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      pickerRow
      browseLink
    }
    .onChange(of: presentationFingerprint, initial: true) { _, _ in
      cachedPresentation = presentationWorker.compute(input: presentationInput)
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

  @ViewBuilder private var pickerContent: some View {
    // onChange(initial:) fires after the first body pass; without this, the
    // selection has no matching tag on that first render (SwiftUI fault).
    if cachedPresentation.sections.isEmpty {
      Text(selectedModelID).tag(selectedModelID)
    }
    ForEach(cachedPresentation.sections, id: \.title) { section in
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
    .harnessActionButtonStyle(variant: .bordered)
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
    if let displayName = cachedPresentation.displayName(for: selectedModelID) {
      return displayName
    }
    return selectedModelID
  }
}
