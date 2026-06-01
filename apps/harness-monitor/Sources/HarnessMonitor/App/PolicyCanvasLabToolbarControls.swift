import HarnessMonitorUIPreviewable
import SwiftUI

private enum PolicyCanvasLabAlgorithmPreset: String, CaseIterable, Identifiable {
  case harnessCurrent
  case referencePure
  case custom

  var id: String { rawValue }

  var label: String {
    switch self {
    case .harnessCurrent: "Harness Current"
    case .referencePure: "Reference Pure"
    case .custom: "Custom Chain"
    }
  }

  var systemImage: String {
    switch self {
    case .harnessCurrent: "checklist.checked"
    case .referencePure: "book.closed"
    case .custom: "slider.horizontal.3"
    }
  }

  var helpText: String {
    switch self {
    case .harnessCurrent:
      "Use the current Harness production algorithm chain."
    case .referencePure:
      "Use the complete reference algorithm chain."
    case .custom:
      "The algorithm chain has per-stage custom selections."
    }
  }

  static func resolved(
    for selection: PolicyCanvasAlgorithmSelection
  ) -> Self {
    if selection.cacheIdentity == PolicyCanvasAlgorithmSelection.harnessCurrent.cacheIdentity {
      return .harnessCurrent
    }
    if selection.cacheIdentity == PolicyCanvasAlgorithmSelection.referencePure.cacheIdentity {
      return .referencePure
    }
    return .custom
  }
}

struct PolicyCanvasLabAlgorithmPresetPicker: View {
  @Binding var algorithmSelection: PolicyCanvasAlgorithmSelection

  private var selectedPreset: PolicyCanvasLabAlgorithmPreset {
    PolicyCanvasLabAlgorithmPreset.resolved(for: algorithmSelection)
  }

  private var presetBinding: Binding<PolicyCanvasLabAlgorithmPreset> {
    Binding(
      get: { selectedPreset },
      set: { preset in
        switch preset {
        case .harnessCurrent:
          algorithmSelection = .harnessCurrent
        case .referencePure:
          algorithmSelection = .referencePure
        case .custom:
          break
        }
      }
    )
  }

  var body: some View {
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
      Text(descriptor.stage.labToolbarLabel)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .help("\(descriptor.label): \(selectedOptionName)")
    .accessibilityLabel(descriptor.label)
    .accessibilityValue(selectedOptionName)
  }
}

struct PolicyCanvasLabThemePicker: View {
  @Binding var canvasThemeMode: PolicyCanvasThemeMode

  var body: some View {
    Menu {
      Picker("Canvas theme", selection: $canvasThemeMode) {
        ForEach(PolicyCanvasThemeMode.allCases) { mode in
          Label(mode.label, systemImage: mode.labToolbarSystemImage).tag(mode)
        }
      }
      .pickerStyle(.inline)
    } label: {
      Image(systemName: canvasThemeMode.labToolbarSystemImage)
        .accessibilityHidden(true)
    }
    .help(
      "Choose whether policy canvas surfaces follow the app theme "
        + "or use a canvas-only light or dark override."
    )
    .accessibilityLabel("Canvas theme")
    .accessibilityValue(canvasThemeMode.label)
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

extension PolicyCanvasThemeMode {
  fileprivate var labToolbarSystemImage: String {
    switch self {
    case .useAppTheme: "circle.lefthalf.filled"
    case .light: "sun.max"
    case .dark: "moon"
    }
  }
}
