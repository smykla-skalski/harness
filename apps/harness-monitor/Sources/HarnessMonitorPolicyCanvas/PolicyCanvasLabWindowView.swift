import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

public struct PolicyCanvasLabWindowView: View {
  private let liveSnapshot: PolicyCanvasHostSnapshot
  private let runtime: (any PolicyCanvasLabRuntime)?
  private let allowsLiveBootstrap: Bool
  private let fixtureDocument: TaskBoardPolicyPipelineDocument?

  @State private var displayedSnapshot: PolicyCanvasHostSnapshot
  @State private var allowsEmptyLiveSnapshot: Bool
  @State private var sampleSelection: PolicyCanvasLabSelection
  @State private var algorithmSelection: PolicyCanvasAlgorithmSelection
  @State private var includesGroupsInLayout = true
  @AppStorage(PolicyCanvasThemeDefaults.modeKey)
  private var canvasThemeMode = PolicyCanvasThemeMode.defaultValue

  @MainActor
  public init(
    liveSnapshot: PolicyCanvasHostSnapshot? = nil,
    runtime: (any PolicyCanvasLabRuntime)? = nil,
    allowsLiveBootstrap: Bool = false,
    initialSelection: PolicyCanvasLabSelection = .sample(PolicyCanvasLabSamples.defaultSelectionID),
    fixtureDocument: TaskBoardPolicyPipelineDocument? =
      PolicyCanvasLabSnapshotSupport.fixtureDocument()
  ) {
    let resolvedLiveSnapshot =
      liveSnapshot
      ?? PolicyCanvasHostSnapshot(
        activeCanvasId: nil,
        document: nil,
        simulation: nil,
        audit: nil
      )
    let liveGraphVisible =
      resolvedLiveSnapshot.document.map(
        PolicyCanvasLabSnapshotSupport.hasVisibleGraph
      ) ?? false
    let normalizedSelection = Self.normalizedInitialSelection(
      initialSelection,
      fixtureDocument: fixtureDocument,
      liveGraphVisible: liveGraphVisible,
      allowsLiveBootstrap: allowsLiveBootstrap
    )

    self.liveSnapshot = resolvedLiveSnapshot
    self.runtime = runtime
    self.allowsLiveBootstrap = allowsLiveBootstrap
    self.fixtureDocument = fixtureDocument
    _displayedSnapshot = State(
      initialValue: Self.displayedSnapshot(
        for: normalizedSelection,
        fixtureDocument: fixtureDocument,
        liveSnapshot: resolvedLiveSnapshot
      )
    )
    _allowsEmptyLiveSnapshot = State(initialValue: liveGraphVisible)
    _sampleSelection = State(initialValue: normalizedSelection)
    _algorithmSelection = State(initialValue: .referenceRouting)
  }

  private static func normalizedInitialSelection(
    _ selection: PolicyCanvasLabSelection,
    fixtureDocument: TaskBoardPolicyPipelineDocument?,
    liveGraphVisible: Bool,
    allowsLiveBootstrap: Bool
  ) -> PolicyCanvasLabSelection {
    if fixtureDocument != nil {
      return sampleSelection(for: selection)
    }
    if liveGraphVisible, allowsLiveBootstrap {
      return .live
    }
    switch selection {
    case .live where liveGraphVisible:
      return .live
    default:
      return sampleSelection(for: selection)
    }
  }

  private static func sampleSelection(
    for selection: PolicyCanvasLabSelection
  ) -> PolicyCanvasLabSelection {
    switch selection {
    case .sample:
      return selection
    case .live:
      return .sample(PolicyCanvasLabSamples.defaultSelectionID)
    }
  }

  private static func displayedSnapshot(
    for selection: PolicyCanvasLabSelection,
    fixtureDocument: TaskBoardPolicyPipelineDocument?,
    liveSnapshot: PolicyCanvasHostSnapshot
  ) -> PolicyCanvasHostSnapshot {
    if let fixtureDocument {
      return PolicyCanvasHostSnapshot(
        activeCanvasId: nil,
        document: fixtureDocument,
        simulation: nil,
        audit: nil
      )
    }
    switch selection {
    case .live:
      return liveSnapshot
    case .sample(let id):
      return PolicyCanvasHostSnapshot(
        activeCanvasId: nil,
        document: PolicyCanvasLabSamples.sample(id: id)?.document,
        simulation: nil,
        audit: nil
      )
    }
  }

  private var usesFixtureDocument: Bool {
    fixtureDocument != nil
  }

  private var renderedPolicyDocument: TaskBoardPolicyPipelineDocument? {
    PolicyCanvasLabSnapshotSupport.document(
      displayedSnapshot.document,
      includesGroups: includesGroupsInLayout
    )
  }

  public var body: some View {
    PolicyCanvasViewportSurface(
      document: renderedPolicyDocument,
      simulation: displayedSnapshot.simulation,
      audit: displayedSnapshot.audit,
      algorithmSelection: algorithmSelection
    )
    .policyCanvasThemeScope()
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        samplePicker
      }
      ToolbarItem(placement: .primaryAction) {
        PolicyCanvasLabGroupsToggle(includesGroupsInLayout: $includesGroupsInLayout)
      }
      ToolbarItem(placement: .primaryAction) {
        PolicyCanvasLabAlgorithmPresetPicker(algorithmSelection: $algorithmSelection)
      }
      PolicyCanvasLabStageToolbar(algorithmSelection: $algorithmSelection)
      ToolbarItem(placement: .primaryAction) {
        PolicyCanvasLabThemePicker(canvasThemeMode: $canvasThemeMode)
      }
    }
    .task {
      if allowsLiveBootstrap, !usesFixtureDocument {
        await bootstrapLivePolicy()
      }
    }
    .onChange(of: liveSnapshot) { _, newSnapshot in
      liveSnapshotDidChange(newSnapshot)
    }
    .onChange(of: sampleSelection) { _, newSelection in
      applySelection(newSelection)
    }
  }

  @ViewBuilder private var samplePicker: some View {
    Menu {
      Picker("Sample policy", selection: $sampleSelection) {
        if allowsEmptyLiveSnapshot {
          Text("Live policy").tag(PolicyCanvasLabSelection.live)
        }
        ForEach(PolicyCanvasLabSamples.all) { sample in
          Text(sample.name).tag(PolicyCanvasLabSelection.sample(sample.id))
        }
      }
      .pickerStyle(.inline)
    } label: {
      PolicyCanvasLabToolbarTextMenuLabel(title: samplePickerTitle)
        .font(.caption.weight(.semibold))
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .controlSize(.small)
    .disabled(usesFixtureDocument)
    .accessibilityLabel("Sample policy")
    .accessibilityValue(samplePickerTitle)
    .help(
      usesFixtureDocument
        ? "A fixture document override is active for this lab host."
        : "Render a built-in sample policy using its authored layout to inspect graphs from trivial to extremely complex."
    )
  }

  private var samplePickerTitle: String {
    if usesFixtureDocument {
      return "Fixture document"
    }
    switch sampleSelection {
    case .live:
      return "Live policy"
    case .sample(let id):
      return PolicyCanvasLabSamples.sample(id: id)?.name ?? "Sample policy"
    }
  }

  @MainActor
  private func bootstrapLivePolicy() async {
    guard let runtime else {
      return
    }
    await runtime.bootstrapPolicyCanvas()
    await runtime.refreshPolicyCanvas()
    adoptLiveSnapshotIfNeeded(runtime.policyCanvasSnapshot)
  }

  @MainActor
  private func liveSnapshotDidChange(_ snapshot: PolicyCanvasHostSnapshot) {
    guard !usesFixtureDocument else {
      return
    }
    if allowsLiveBootstrap {
      adoptLiveSnapshotIfNeeded(snapshot)
    } else if sampleSelection == .live {
      displayedSnapshot = snapshot
    }
  }

  @MainActor
  private func adoptLiveSnapshotIfNeeded(_ snapshot: PolicyCanvasHostSnapshot) {
    guard
      PolicyCanvasLabSnapshotSupport.shouldAdoptLiveSnapshot(
        document: snapshot.document,
        allowsEmptyLiveSnapshot: allowsEmptyLiveSnapshot
      )
    else {
      return
    }

    let liveBecameVisible =
      snapshot.document.map(PolicyCanvasLabSnapshotSupport.hasVisibleGraph) ?? false
    if liveBecameVisible, !allowsEmptyLiveSnapshot {
      allowsEmptyLiveSnapshot = true
      sampleSelection = .live
    }

    if sampleSelection == .live {
      displayedSnapshot = snapshot
    }
  }

  @MainActor
  private func applySelection(_ selection: PolicyCanvasLabSelection) {
    displayedSnapshot = Self.displayedSnapshot(
      for: selection,
      fixtureDocument: fixtureDocument,
      liveSnapshot: liveSnapshot
    )
  }
}
