import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct PolicyCanvasLabSeed {
  let document: TaskBoardPolicyPipelineDocument
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
  let allowsEmptyLiveSnapshot: Bool
}

enum PolicyCanvasLabSnapshotSupport {
  static func initialSeed(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?
  ) -> PolicyCanvasLabSeed {
    if let document, hasVisibleGraph(document) {
      return PolicyCanvasLabSeed(
        document: document,
        simulation: simulation,
        audit: audit,
        allowsEmptyLiveSnapshot: true
      )
    }

    let previewDocument = PreviewFixtures.policyCanvasPipelineDocument()
    return PolicyCanvasLabSeed(
      document: previewDocument,
      simulation: nil,
      audit: PreviewFixtures.policyCanvasAudit(for: previewDocument),
      allowsEmptyLiveSnapshot: false
    )
  }

  static func shouldAdoptLiveSnapshot(
    document: TaskBoardPolicyPipelineDocument?,
    allowsEmptyLiveSnapshot: Bool
  ) -> Bool {
    guard let document else {
      return false
    }
    return allowsEmptyLiveSnapshot || hasVisibleGraph(document)
  }

  static func hasVisibleGraph(_ document: TaskBoardPolicyPipelineDocument) -> Bool {
    !document.nodes.isEmpty
  }

  /// Names the env vars the `monitor:policy-lab:capture` task uses to hand the lab
  /// a specific pipeline-document JSON (snake_case, the daemon's `policy_pipeline_get`
  /// shape) to render directly instead of a sample or the live daemon snapshot. Base64
  /// content is preferred because it survives the app sandbox with no file-read
  /// permission; the path variant stays for local development outside the sandbox.
  /// When a fixture is set it overrides the picker so an agent can screenshot any
  /// policy without rebuilding to change the default sample.
  static let fixtureBase64EnvKey = "HARNESS_MONITOR_POLICY_CANVAS_LAB_FIXTURE_B64"
  static let fixturePathEnvKey = "HARNESS_MONITOR_POLICY_CANVAS_LAB_FIXTURE"

  static func fixtureEnvIsSet(_ environment: [String: String]) -> Bool {
    !(environment[fixtureBase64EnvKey] ?? "").isEmpty
      || !(environment[fixturePathEnvKey] ?? "").isEmpty
  }

  /// Renders a fixture document when either fixture env var is set. Used to exercise
  /// the layout engine against a specific saved policy without a live daemon.
  static func fixtureDocument() -> TaskBoardPolicyPipelineDocument? {
    let environment = ProcessInfo.processInfo.environment
    let data: Data?
    if let encoded = environment[fixtureBase64EnvKey], !encoded.isEmpty {
      data = Data(base64Encoded: encoded)
    } else if let path = environment[fixturePathEnvKey], !path.isEmpty {
      data = FileManager.default.contents(atPath: path)
    } else {
      return nil
    }
    guard let data else {
      writeFixtureDecodeLog("FAIL no fixture data (bad base64 or unreadable path)")
      return nil
    }
    let snake = JSONDecoder()
    snake.keyDecodingStrategy = .convertFromSnakeCase
    do {
      let document = try snake.decode(TaskBoardPolicyPipelineDocument.self, from: data)
      writeFixtureDecodeLog("OK convertFromSnakeCase nodes=\(document.nodes.count)")
      return document
    } catch {
      if let document = try? JSONDecoder()
        .decode(TaskBoardPolicyPipelineDocument.self, from: data)
      {
        writeFixtureDecodeLog("OK plain nodes=\(document.nodes.count)")
        return document
      }
      writeFixtureDecodeLog("FAIL convertFromSnakeCase: \(error)")
      return nil
    }
  }

  /// Writes the fixture decode outcome into the sandbox home so the capture task can
  /// read it back from the app's container without needing any extra entitlement.
  private static func writeFixtureDecodeLog(_ message: String) {
    let logPath = (NSHomeDirectory() as NSString)
      .appendingPathComponent("policy-canvas-lab-decode.log")
    try? message.write(toFile: logPath, atomically: true, encoding: .utf8)
  }
}

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
  @Binding var themeMode: HarnessMonitorThemeMode
  @State private var dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  @State private var allowsEmptyLiveSnapshot: Bool
  @State private var sampleSelection: PolicyCanvasLabSelection
  @State private var algorithmSelection: PolicyCanvasAlgorithmSelection
  @AppStorage(PolicyCanvasThemeDefaults.modeKey)
  private var canvasThemeMode = PolicyCanvasThemeMode.defaultValue

  @MainActor
  init(
    store: HarnessMonitorStore,
    keyWindowObserver: KeyWindowObserver,
    windowCommandRouting: WindowCommandRoutingState,
    mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar,
    themeMode: Binding<HarnessMonitorThemeMode>
  ) {
    self.store = store
    self.keyWindowObserver = keyWindowObserver
    self.windowCommandRouting = windowCommandRouting
    self.mcpWindowCommandRegistrar = mcpWindowCommandRegistrar
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
      toast: store.toast
    ) {
      PolicyCanvasViewportSurface(
        document: dashboardUI.taskBoardPolicyPipeline,
        simulation: dashboardUI.taskBoardPolicySimulation,
        audit: dashboardUI.taskBoardPolicyAudit,
        algorithmSelection: algorithmSelection
      )
      .toolbar {
        PolicyEnforcementKillSwitchToolbarGroup(store: store)
        ToolbarSpacer(.fixed, placement: .primaryAction)
          .sharedBackgroundVisibility(.hidden)

        ToolbarItem {
          samplePicker
        }
        ToolbarItem {
          algorithmMenu
        }
        ToolbarItem {
          Picker("Canvas theme", selection: $canvasThemeMode) {
            ForEach(PolicyCanvasThemeMode.allCases) { mode in
              Text(mode.label).tag(mode)
            }
          }
          .help(
            "Choose whether policy canvas surfaces follow the app theme "
              + "or use a canvas-only light or dark override."
          )
        }
      }
    }
    .task {
      if !usesFixtureDocument {
        await bootstrapLivePolicy()
      }
    }
    .onChange(of: liveSnapshot) { _, newSnapshot in
      if !usesFixtureDocument {
        adoptLiveSnapshotIfNeeded(newSnapshot)
      }
    }
    .onChange(of: sampleSelection) { _, newSelection in
      applySelection(newSelection)
    }
  }

  @ViewBuilder private var samplePicker: some View {
    Picker("Sample policy", selection: $sampleSelection) {
      if allowsEmptyLiveSnapshot {
        Text("Live policy").tag(PolicyCanvasLabSelection.live)
      }
      ForEach(PolicyCanvasLabSamples.all) { sample in
        Text(sample.name).tag(PolicyCanvasLabSelection.sample(sample.id))
      }
    }
    .help(
      "Render a built-in sample policy using its authored layout to inspect "
        + "graphs from trivial to extremely complex."
    )
  }

  @ViewBuilder private var algorithmMenu: some View {
    Menu {
      Button("Harness Current") {
        algorithmSelection = .harnessCurrent
      }
      Button("Reference Pure") {
        algorithmSelection = .referencePure
      }
      Divider()
      ForEach(PolicyCanvasAlgorithmPickerCatalog.stageDescriptors) { descriptor in
        Picker(descriptor.label, selection: algorithmBinding(for: descriptor.stage)) {
          ForEach(descriptor.options) { option in
            Text(option.name).tag(option.id)
          }
        }
      }
    } label: {
      Label("Algorithms", systemImage: "slider.horizontal.3")
    }
    .help("Choose concrete layout and routing algorithms for the Policy Canvas Lab.")
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
