import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

private struct PolicyCanvasLabLiveSnapshot: Equatable {
  let document: TaskBoardPolicyPipelineDocument?
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
}

struct PolicyCanvasLabWindowView: View {
  private static let minimumSize = CGSize(width: 0, height: 620)

  let store: HarnessMonitorStore
  let keyWindowObserver: KeyWindowObserver
  let windowCommandRouting: WindowCommandRoutingState
  let mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  let allowsLiveBootstrap: Bool
  @Binding var themeMode: HarnessMonitorThemeMode
  @State private var dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  @State private var allowsEmptyLiveSnapshot: Bool
  @State private var sampleSelection: PolicyCanvasLabSelection
  @State private var algorithmSelection: PolicyCanvasAlgorithmSelection
  @State private var includesGroupsInLayout = true
  @AppStorage(PolicyCanvasThemeDefaults.modeKey)
  private var canvasThemeMode = PolicyCanvasThemeMode.defaultValue

  @MainActor
  init(
    store: HarnessMonitorStore,
    keyWindowObserver: KeyWindowObserver,
    windowCommandRouting: WindowCommandRoutingState,
    mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar,
    allowsLiveBootstrap: Bool = true,
    themeMode: Binding<HarnessMonitorThemeMode>
  ) {
    self.store = store
    self.keyWindowObserver = keyWindowObserver
    self.windowCommandRouting = windowCommandRouting
    self.mcpWindowCommandRegistrar = mcpWindowCommandRegistrar
    self.allowsLiveBootstrap = allowsLiveBootstrap
    _themeMode = themeMode

    let seed = PolicyCanvasLabSnapshotSupport.initialSeed(
      document: store.contentUI.dashboard.taskBoardPolicyPipeline,
      simulation: store.contentUI.dashboard.taskBoardPolicySimulation,
      audit: store.contentUI.dashboard.taskBoardPolicyAudit
    )
    // A live policy adopts the `.live` selection so its tag matches; otherwise
    // start on the default sample so the picker reflects what is rendered and
    // the canvas shows a compiled-in sample rather than the preview fixture.
    let startsLive = seed.allowsEmptyLiveSnapshot
    let initialSelection: PolicyCanvasLabSelection =
      startsLive ? .live : .sample(PolicyCanvasLabSamples.defaultSelectionID)

    let dashboardUI = HarnessMonitorStore.ContentDashboardSlice()
    if let fixture = PolicyCanvasLabSnapshotSupport.fixtureDocument() {
      // A fixture env overrides the picker so agent capture renders an exact
      // policy document; the live bootstrap and sample selection are skipped.
      dashboardUI.taskBoardPolicyPipeline = fixture
    } else if startsLive {
      dashboardUI.taskBoardPolicyPipeline = seed.document
      dashboardUI.taskBoardPolicySimulation = seed.simulation
      dashboardUI.taskBoardPolicyAudit = seed.audit
    } else {
      dashboardUI.taskBoardPolicyPipeline =
        Self.document(for: initialSelection, fallback: seed.document)
    }
    _dashboardUI = State(initialValue: dashboardUI)
    _allowsEmptyLiveSnapshot = State(initialValue: startsLive)
    _sampleSelection = State(initialValue: initialSelection)
    _algorithmSelection = State(initialValue: .harnessCurrent)
  }

  private static func document(
    for selection: PolicyCanvasLabSelection,
    fallback: TaskBoardPolicyPipelineDocument
  ) -> TaskBoardPolicyPipelineDocument {
    switch selection {
    case .live:
      return fallback
    case .sample(let id):
      return PolicyCanvasLabSamples.sample(id: id)?.document ?? fallback
    }
  }

  private var liveSnapshot: PolicyCanvasLabLiveSnapshot {
    PolicyCanvasLabLiveSnapshot(
      document: store.contentUI.dashboard.taskBoardPolicyPipeline,
      simulation: store.contentUI.dashboard.taskBoardPolicySimulation,
      audit: store.contentUI.dashboard.taskBoardPolicyAudit
    )
  }

  private var usesFixtureDocument: Bool {
    PolicyCanvasLabSnapshotSupport.fixtureEnvIsSet(ProcessInfo.processInfo.environment)
  }

  private var renderedPolicyDocument: TaskBoardPolicyPipelineDocument? {
    PolicyCanvasLabSnapshotSupport.document(
      dashboardUI.taskBoardPolicyPipeline,
      includesGroups: includesGroupsInLayout
    )
  }

  var body: some View {
    HarnessMonitorWindowShell(
      windowID: HarnessMonitorWindowID.policyCanvasLab,
      windowTitle: "Policy Canvas Lab",
      scope: .main,
      minimumSize: Self.minimumSize,
      keyWindowObserver: keyWindowObserver,
      windowCommandRouting: windowCommandRouting,
      mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
      themeMode: $themeMode,
      appliesPreferredColorScheme: true,
      windowToolbarBackgroundVisibility: .automatic,
      toast: nil,
      handlesPinchToZoomTextSize: false,
      appliesWindowBackdrop: false,
      tracksWindowCommandScope: false,
      installsMCPWindowCommands: false
    ) {
      PolicyCanvasViewportSurface(
        document: renderedPolicyDocument,
        simulation: dashboardUI.taskBoardPolicySimulation,
        audit: dashboardUI.taskBoardPolicyAudit,
        algorithmSelection: algorithmSelection
      )
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          samplePicker
          PolicyCanvasLabGroupsToggle(includesGroupsInLayout: $includesGroupsInLayout)
          PolicyCanvasLabAlgorithmPresetPicker(algorithmSelection: $algorithmSelection)
          ForEach(PolicyCanvasAlgorithmPickerCatalog.stageDescriptors) { descriptor in
            PolicyCanvasLabAlgorithmStagePicker(
              descriptor: descriptor,
              selectedID: algorithmBinding(for: descriptor.stage)
            )
          }
          PolicyCanvasLabThemePicker(canvasThemeMode: $canvasThemeMode)
        }
        .sharedBackgroundVisibility(.automatic)
      }
    }
    .task {
      if allowsLiveBootstrap, !usesFixtureDocument {
        await bootstrapLivePolicy()
      }
    }
    .onChange(of: liveSnapshot) { _, newSnapshot in
      if allowsLiveBootstrap, !usesFixtureDocument {
        adoptLiveSnapshotIfNeeded(newSnapshot)
      }
    }
    .onChange(of: sampleSelection) { _, newSelection in
      applySelection(newSelection)
    }
  }

  @ViewBuilder private var samplePicker: some View {
    Menu {
      if allowsEmptyLiveSnapshot {
        sampleMenuItem(title: "Live policy", selection: .live)
      }
      ForEach(PolicyCanvasLabSamples.all) { sample in
        sampleMenuItem(title: sample.name, selection: .sample(sample.id))
      }
    } label: {
      PolicyCanvasLabToolbarTextMenuLabel(title: samplePickerTitle)
        .font(.caption.weight(.semibold))
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .controlSize(.small)
    .accessibilityLabel("Sample policy")
    .accessibilityValue(samplePickerTitle)
    .help(
      "Render a built-in sample policy using its authored layout to inspect "
        + "graphs from trivial to extremely complex."
    )
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

  private var samplePickerTitle: String {
    switch sampleSelection {
    case .live:
      return "Live policy"
    case .sample(let id):
      return PolicyCanvasLabSamples.sample(id: id)?.name ?? "Sample policy"
    }
  }

  @ViewBuilder
  private func sampleMenuItem(
    title: String,
    selection: PolicyCanvasLabSelection
  ) -> some View {
    Button {
      sampleSelection = selection
    } label: {
      selectionLabel(title, isSelected: sampleSelection == selection)
    }
  }

  @ViewBuilder
  private func selectionLabel(_ title: String, isSelected: Bool) -> some View {
    if isSelected {
      Label(title, systemImage: "checkmark")
    } else {
      Text(title)
    }
  }

  @MainActor
  private func bootstrapLivePolicy() async {
    await store.bootstrapIfNeeded()
    await store.refreshTaskBoardPolicyPipeline()
    adoptLiveSnapshotIfNeeded(liveSnapshot)
  }

  @MainActor
  private func adoptLiveSnapshotIfNeeded(_ snapshot: PolicyCanvasLabLiveSnapshot) {
    guard
      PolicyCanvasLabSnapshotSupport.shouldAdoptLiveSnapshot(
        document: snapshot.document,
        allowsEmptyLiveSnapshot: allowsEmptyLiveSnapshot
      )
    else {
      return
    }

    dashboardUI.taskBoardPolicySimulation = snapshot.simulation
    dashboardUI.taskBoardPolicyAudit = snapshot.audit

    let liveBecameVisible =
      snapshot.document.map(PolicyCanvasLabSnapshotSupport.hasVisibleGraph) ?? false
    if liveBecameVisible, !allowsEmptyLiveSnapshot {
      // First live graph this session: enable the Live tag and prefer it.
      allowsEmptyLiveSnapshot = true
      sampleSelection = .live
    }

    // Only the live snapshot drives the canvas while the picker is on `.live`;
    // a chosen sample keeps rendering even when the live policy refreshes.
    if sampleSelection == .live {
      dashboardUI.taskBoardPolicyPipeline = snapshot.document
    }
  }

  @MainActor
  private func applySelection(_ selection: PolicyCanvasLabSelection) {
    switch selection {
    case .live:
      dashboardUI.taskBoardPolicyPipeline = liveSnapshot.document
      dashboardUI.taskBoardPolicySimulation = liveSnapshot.simulation
      dashboardUI.taskBoardPolicyAudit = liveSnapshot.audit
    case .sample(let id):
      guard let sample = PolicyCanvasLabSamples.sample(id: id) else {
        return
      }
      dashboardUI.taskBoardPolicyPipeline = sample.document
      dashboardUI.taskBoardPolicySimulation = nil
      dashboardUI.taskBoardPolicyAudit = nil
    }
  }
}
