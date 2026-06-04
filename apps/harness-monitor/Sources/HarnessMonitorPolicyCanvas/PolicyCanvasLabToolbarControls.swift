import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

private enum PolicyCanvasLabAlgorithmPreset: String, CaseIterable, Identifiable {
  case referenceRouting
  case referencePure
  case custom

  var id: String { rawValue }

  var label: String {
    switch self {
    case .referenceRouting: "Reference Routing"
    case .referencePure: "Reference Pure"
    case .custom: "Custom Chain"
    }
  }

  var systemImage: String {
    switch self {
    case .referenceRouting: "checklist.checked"
    case .referencePure: "book.closed"
    case .custom: "slider.horizontal.3"
    }
  }

  var helpText: String {
    switch self {
    case .referenceRouting:
      "Use the production chain: harness layout with reference-form routing."
    case .referencePure:
      "Use the complete reference algorithm chain."
    case .custom:
      "The algorithm chain has per-stage custom selections."
    }
  }

  static func resolved(
    for selection: PolicyCanvasAlgorithmSelection
  ) -> Self {
    if selection.cacheIdentity == PolicyCanvasAlgorithmSelection.referenceRouting.cacheIdentity {
      return .referenceRouting
    }
    if selection.cacheIdentity == PolicyCanvasAlgorithmSelection.referencePure.cacheIdentity {
      return .referencePure
    }
    return .custom
  }
}

public struct PolicyCanvasLabAlgorithmPresetPicker: View {
  @Binding var algorithmSelection: PolicyCanvasAlgorithmSelection

  public init(algorithmSelection: Binding<PolicyCanvasAlgorithmSelection>) {
    _algorithmSelection = algorithmSelection
  }

  private var selectedPreset: PolicyCanvasLabAlgorithmPreset {
    PolicyCanvasLabAlgorithmPreset.resolved(for: algorithmSelection)
  }

  private var presetBinding: Binding<PolicyCanvasLabAlgorithmPreset> {
    Binding(
      get: { selectedPreset },
      set: { preset in
        switch preset {
        case .referenceRouting:
          algorithmSelection = .referenceRouting
        case .referencePure:
          algorithmSelection = .referencePure
        case .custom:
          break
        }
      }
    )
  }

  public var body: some View {
    Menu {
      Picker("Algorithm chain preset", selection: presetBinding) {
        ForEach(PolicyCanvasLabAlgorithmPreset.allCases) { preset in
          Label(preset.label, systemImage: preset.systemImage).tag(preset)
        }
      }
      .pickerStyle(.inline)
    } label: {
      Image(systemName: selectedPreset.systemImage)
        .accessibilityHidden(true)
    }
    .help(selectedPreset.helpText)
    .accessibilityLabel("Algorithm chain preset")
    .accessibilityValue(selectedPreset.label)
  }
}

struct PolicyCanvasLabAlgorithmStagePicker: View {
  let descriptor: PolicyCanvasAlgorithmStageDescriptor
  @Binding var selectedID: PolicyCanvasAlgorithmID

  private var selectedOptionName: String {
    descriptor.options.first { $0.id == selectedID }?.name ?? selectedID.rawValue
  }

  var body: some View {
    Menu {
      Picker(descriptor.label, selection: $selectedID) {
        ForEach(descriptor.options) { option in
          Text(option.name).tag(option.id)
        }
      }
      .pickerStyle(.inline)
    } label: {
      PolicyCanvasLabToolbarTextMenuLabel(title: descriptor.stage.labToolbarLabel)
        .font(.caption.weight(.semibold))
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .controlSize(.small)
    .help("\(descriptor.label): \(selectedOptionName)")
    .accessibilityLabel(descriptor.label)
    .accessibilityValue(selectedOptionName)
  }
}

public struct PolicyCanvasLabStageToolbar: ToolbarContent {
  @Binding var algorithmSelection: PolicyCanvasAlgorithmSelection

  public init(algorithmSelection: Binding<PolicyCanvasAlgorithmSelection>) {
    _algorithmSelection = algorithmSelection
  }

  @ToolbarContentBuilder public var body: some ToolbarContent {
    primaryStageToolbarItems
    secondaryStageToolbarItems
  }

  @ToolbarContentBuilder private var primaryStageToolbarItems: some ToolbarContent {
    algorithmStageToolbarItem(.cycleBreaking)
    algorithmStageToolbarItem(.rankAssignment)
    algorithmStageToolbarItem(.longEdgeNormalization)
    algorithmStageToolbarItem(.layerOrdering)
    algorithmStageToolbarItem(.coordinateAssignment)
    algorithmStageToolbarItem(.groupPlacement)
    algorithmStageToolbarItem(.layoutPostProcessing)
    algorithmStageToolbarItem(.portMarkerPlacement)
    algorithmStageToolbarItem(.edgeRouting)
  }

  @ToolbarContentBuilder private var secondaryStageToolbarItems: some ToolbarContent {
    algorithmStageToolbarItem(.routeSelection)
    algorithmStageToolbarItem(.routePostProcessing)
    algorithmStageToolbarItem(.labelPlacement)
    algorithmStageToolbarItem(.metrics)
  }

  @ToolbarContentBuilder
  private func algorithmStageToolbarItem(
    _ stage: PolicyCanvasAlgorithmStage
  ) -> some ToolbarContent {
    if let descriptor = PolicyCanvasAlgorithmPickerCatalog.stageDescriptors.first(
      where: { $0.stage == stage }
    ) {
      ToolbarItem(placement: .primaryAction) {
        PolicyCanvasLabAlgorithmStagePicker(
          descriptor: descriptor,
          selectedID: algorithmBinding(for: descriptor.stage)
        )
      }
    }
  }

  private func algorithmBinding(
    for stage: PolicyCanvasAlgorithmStage
  ) -> Binding<PolicyCanvasAlgorithmID> {
    Binding(
      get: {
        algorithmSelection.algorithmID(for: stage)
      },
      set: { id in
        algorithmSelection = algorithmSelection.replacing(stage: stage, with: id)
      }
    )
  }
}

public struct PolicyCanvasLabGroupsToggle: View {
  @Binding var includesGroupsInLayout: Bool

  public init(includesGroupsInLayout: Binding<Bool>) {
    _includesGroupsInLayout = includesGroupsInLayout
  }

  public var body: some View {
    Toggle(isOn: $includesGroupsInLayout) {
      Text("Groups")
        .font(.caption.weight(.semibold))
    }
    .toggleStyle(.switch)
    .controlSize(.small)
    .help(
      includesGroupsInLayout
        ? "Policy groups are included in canvas rendering, layout, and routing inputs."
        : "Policy groups are stripped before canvas rendering, layout, and routing inputs."
    )
    .accessibilityLabel("Policy groups")
    .accessibilityValue(includesGroupsInLayout ? "Enabled" : "Disabled")
  }
}

public struct PolicyCanvasLabThemePicker: View {
  @Binding var windowThemeMode: PolicyCanvasLabThemeMode

  public init(windowThemeMode: Binding<PolicyCanvasLabThemeMode>) {
    _windowThemeMode = windowThemeMode
  }

  public var body: some View {
    Menu {
      Picker("Window theme", selection: $windowThemeMode) {
        ForEach(PolicyCanvasLabThemeMode.allCases) { mode in
          Label(mode.label, systemImage: mode.labToolbarSystemImage).tag(mode)
        }
      }
      .pickerStyle(.inline)
    } label: {
      Image(systemName: windowThemeMode.labToolbarSystemImage)
        .accessibilityHidden(true)
    }
    .help(
      "Choose the Policy Canvas Lab window theme."
    )
    .accessibilityLabel("Window theme")
    .accessibilityValue(windowThemeMode.label)
  }
}

extension PolicyCanvasAlgorithmStage {
  fileprivate var labToolbarLabel: String {
    switch self {
    case .cycleBreaking: "Cycle"
    case .rankAssignment: "Rank"
    case .longEdgeNormalization: "Long-edge"
    case .layerOrdering: "Layer"
    case .coordinateAssignment: "Coordinate"
    case .groupPlacement: "Group"
    case .layoutPostProcessing: "Layout"
    case .portMarkerPlacement: "Port"
    case .edgeRouting: "Edge"
    case .routeSelection: "Route"
    case .routePostProcessing: "Route"
    case .labelPlacement: "Label"
    case .metrics: "Metrics"
    }
  }
}

extension PolicyCanvasLabThemeMode {
  fileprivate var labToolbarSystemImage: String {
    switch self {
    case .light: "sun.max"
    case .dark: "moon"
    }
  }
}

public struct PolicyCanvasLabToolbarTextMenuLabel: View {
  let title: String

  public init(title: String) {
    self.title = title
  }

  @ScaledMetric(relativeTo: .callout)
  private var itemSpacing = 6.0

  public var body: some View {
    HStack(spacing: itemSpacing) {
      Text(title)
        .lineLimit(1)
        .truncationMode(.tail)
      Image(systemName: "chevron.down")
        .imageScale(.small)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityHidden(true)
    }
  }
}
