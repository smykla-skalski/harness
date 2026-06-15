import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

final class PolicyCanvasLabWindowViewTests: XCTestCase {
  func testInitialSeedFallsBackToPreviewFixtureWhenLiveDocumentIsMissing() {
    let seed = PolicyCanvasLabSnapshotSupport.initialSeed(
      document: nil,
      simulation: nil,
      audit: nil
    )

    XCTAssertFalse(seed.allowsEmptyLiveSnapshot)
    XCTAssertEqual(
      seed.document.nodes.map(\.id),
      PreviewFixtures.policyCanvasPipelineDocument().nodes.map(\.id)
    )
    XCTAssertEqual(seed.audit?.activeRevision, seed.document.revision)
  }

  func testInitialSeedUsesLiveDocumentWhenGraphExists() {
    let liveDocument = PreviewFixtures.policyCanvasPipelineDocument(revision: 7)
    let liveAudit = PreviewFixtures.policyCanvasAudit(for: liveDocument)

    let seed = PolicyCanvasLabSnapshotSupport.initialSeed(
      document: liveDocument,
      simulation: nil,
      audit: liveAudit
    )

    XCTAssertTrue(seed.allowsEmptyLiveSnapshot)
    XCTAssertEqual(seed.document.revision, 7)
    XCTAssertEqual(seed.audit?.activeRevision, 7)
  }

  func testShouldAdoptLiveSnapshotRejectsEmptyGraphUntilLiveDataArrives() {
    let emptyDocument = TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: 9,
      mode: .draft,
      nodes: [],
      edges: [],
      groups: [],
      layout: TaskBoardPolicyPipelineLayout(nodes: []),
      policyTraceIds: ["trace-empty"]
    )

    XCTAssertFalse(
      PolicyCanvasLabSnapshotSupport.shouldAdoptLiveSnapshot(
        document: emptyDocument,
        allowsEmptyLiveSnapshot: false
      )
    )
    XCTAssertTrue(
      PolicyCanvasLabSnapshotSupport.shouldAdoptLiveSnapshot(
        document: emptyDocument,
        allowsEmptyLiveSnapshot: true
      )
    )
  }

  func testLabDocumentCanStripPolicyGroupsBeforeCanvasImport() throws {
    let document = try XCTUnwrap(PolicyCanvasLabSamples.sample(id: "default")?.document)

    XCTAssertFalse(document.groups.isEmpty)
    XCTAssertTrue(document.nodes.contains { $0.groupId != nil })

    let strippedDocument = try XCTUnwrap(
      PolicyCanvasLabSnapshotSupport.document(document, includesGroups: false)
    )

    XCTAssertTrue(strippedDocument.groups.isEmpty)
    XCTAssertTrue(strippedDocument.nodes.allSatisfy { $0.groupId == nil })
    XCTAssertEqual(strippedDocument.edges, document.edges)
    XCTAssertEqual(strippedDocument.layout, document.layout)
  }

  func testLabDocumentPreservesPolicyGroupsWhenEnabled() throws {
    let document = try XCTUnwrap(PolicyCanvasLabSamples.sample(id: "default")?.document)

    XCTAssertEqual(
      PolicyCanvasLabSnapshotSupport.document(document, includesGroups: true),
      document
    )
  }

  func testUseAppThemeCanvasModeResolvesToTheCurrentAppThemeMode() {
    XCTAssertEqual(
      PolicyCanvasThemeMode.useAppTheme.resolvedThemeMode(appThemeMode: .auto),
      .auto
    )
    XCTAssertEqual(
      PolicyCanvasThemeMode.useAppTheme.resolvedThemeMode(appThemeMode: .light),
      .light
    )
    XCTAssertEqual(
      PolicyCanvasThemeMode.useAppTheme.resolvedThemeMode(appThemeMode: .dark),
      .dark
    )
  }

  func testCanvasThemeModeResolvesColorSchemeForEmbeddedCanvasHosts() {
    XCTAssertNil(PolicyCanvasThemeMode.useAppTheme.resolvedColorScheme(appThemeMode: .auto))
    XCTAssertEqual(
      PolicyCanvasThemeMode.useAppTheme.resolvedColorScheme(appThemeMode: .dark),
      .dark
    )
    XCTAssertEqual(
      PolicyCanvasThemeMode.light.resolvedColorScheme(appThemeMode: .dark),
      .light
    )
    XCTAssertEqual(
      PolicyCanvasThemeMode.dark.resolvedColorScheme(appThemeMode: .light),
      .dark
    )
  }

  func testLabCanvasForcesAutoArrangeSoAlgorithmSwitchesReflow() throws {
    let source = try policyCanvasSourceFile(named: "PolicyCanvasLabWindowView.swift")

    XCTAssertTrue(source.contains("PolicyCanvasViewportSurface("))
    XCTAssertTrue(source.contains("algorithmSelection: algorithmSelection"))
    XCTAssertTrue(source.contains("showsQualityInspection: showsQualityMetrics"))
    XCTAssertTrue(source.contains("usesElkLayoutForSmallGraphs: true"))
  }

  @MainActor
  func testLabElkDefaultAppliesToSmallSamples() throws {
    let sample = try XCTUnwrap(PolicyCanvasLabSamples.sample(id: "default"))
    let viewModel = PolicyCanvasViewModel.liveStartupState(
      document: sample.document,
      simulation: nil,
      audit: nil,
      activeCanvasId: nil,
      policyGroupTitle: sample.name,
      usesElkLayoutForSmallGraphs: true
    )

    viewModel.reflowLayout(preserveManualAnchors: false, force: true)

    XCTAssertEqual(viewModel.precomputedRoutes?.routes.count, viewModel.edges.count)
  }

  func testLabSamplePickerToolbarDoesNotExposeGroupsToggle() throws {
    let windowSource = try policyCanvasSourceFile(named: "PolicyCanvasLabWindowView.swift")
    let controlsSource = try policyCanvasSourceFile(named: "PolicyCanvasLabToolbarControls.swift")

    XCTAssertFalse(windowSource.contains("includesGroupsInLayout"))
    XCTAssertFalse(windowSource.contains("PolicyCanvasLabGroupsToggle"))
    XCTAssertTrue(windowSource.contains("ToolbarItem(placement: .primaryAction)"))
    XCTAssertTrue(
      windowSource.contains(
        "PolicyCanvasLabStageToolbar(algorithmSelection: $algorithmSelection)"
      )
    )
    XCTAssertTrue(controlsSource.contains("struct PolicyCanvasLabStageToolbar"))
    XCTAssertTrue(controlsSource.contains("@ToolbarContentBuilder"))
    XCTAssertFalse(windowSource.contains("ToolbarItemGroup(placement: .primaryAction)"))
    XCTAssertFalse(windowSource.contains(".sharedBackgroundVisibility(.automatic)"))
    XCTAssertFalse(controlsSource.contains("PolicyCanvasLabGroupsToggle"))
    XCTAssertFalse(controlsSource.contains("Toggle(isOn: $includesGroupsInLayout)"))
    XCTAssertFalse(controlsSource.contains("Text(\"Groups\")"))
  }

  func testLabAlgorithmPickersUseSeparateToolbarGlassBubbles() throws {
    let controlsSource = try policyCanvasSourceFile(named: "PolicyCanvasLabToolbarControls.swift")

    XCTAssertTrue(controlsSource.contains("PolicyCanvasLabStageToolbar"))
    XCTAssertTrue(
      controlsSource.contains("ToolbarSpacer(.fixed, placement: .primaryAction)")
    )
    XCTAssertTrue(controlsSource.contains(".sharedBackgroundVisibility(.hidden)"))
    XCTAssertTrue(
      controlsSource.contains(
        "let stageDescriptors = PolicyCanvasAlgorithmPickerCatalog.stageDescriptors"
      )
    )
    XCTAssertTrue(controlsSource.contains("stageDescriptors.firstIndex("))
    XCTAssertTrue(controlsSource.contains("where: { $0.stage == stage }"))
    XCTAssertTrue(
      controlsSource.contains("if stageIndex < stageDescriptors.count - 1")
    )
    XCTAssertFalse(
      controlsSource.contains(
        """
        }
              .sharedBackgroundVisibility(.hidden)
              if stageIndex < stageDescriptors.count - 1 {
        """
      )
    )
    XCTAssertFalse(controlsSource.contains("ToolbarItemGroup(placement: .primaryAction)"))
  }

  func testLabToolbarTextMenusUseNativeButtonChromeOnly() throws {
    let windowSource = try policyCanvasSourceFile(named: "PolicyCanvasLabWindowView.swift")
    let controlsSource = try policyCanvasSourceFile(named: "PolicyCanvasLabToolbarControls.swift")

    XCTAssertTrue(
      windowSource.contains("PolicyCanvasLabToolbarTextMenuLabel(title: samplePickerTitle)")
    )
    XCTAssertTrue(
      controlsSource.contains(
        "PolicyCanvasLabToolbarTextMenuLabel(title: descriptor.stage.labToolbarLabel)"
      )
    )
    XCTAssertTrue(windowSource.contains(".controlSize(.small)"))
    XCTAssertTrue(controlsSource.contains(".controlSize(.small)"))
    XCTAssertTrue(controlsSource.contains("private var horizontalContentPadding = 6.0"))
    XCTAssertTrue(
      controlsSource.contains(".padding(.horizontal, horizontalContentPadding)")
    )
    XCTAssertFalse(windowSource.contains("PolicyCanvasLabToolbarTextMenuStyle"))
    XCTAssertFalse(controlsSource.contains("PolicyCanvasLabToolbarTextMenuStyle"))
    XCTAssertFalse(controlsSource.contains(".harnessControlPill"))
  }

  func testLabSamplePickerUsesNativeInlinePickerBinding() throws {
    let windowSource = try policyCanvasSourceFile(named: "PolicyCanvasLabWindowView.swift")

    XCTAssertTrue(windowSource.contains("Picker(\"Sample policy\", selection: $sampleSelection)"))
    XCTAssertTrue(windowSource.contains(".pickerStyle(.inline)"))
    XCTAssertFalse(windowSource.contains("sampleMenuItem(title:"))
  }

  func testLabToolbarSelectionsPersistToLabScopedDefaults() throws {
    let windowSource = try policyCanvasSourceFile(named: "PolicyCanvasLabWindowView.swift")

    XCTAssertTrue(
      windowSource.contains("@AppStorage(PolicyCanvasLabToolbarDefaults.sampleSelectionKey)")
    )
    XCTAssertTrue(
      windowSource.contains("@AppStorage(PolicyCanvasLabToolbarDefaults.algorithmSelectionKey)")
    )
    XCTAssertTrue(
      windowSource.contains("@AppStorage(PolicyCanvasLabToolbarDefaults.scalesZoomOnResizeKey)")
    )
    XCTAssertTrue(
      windowSource.contains(
        "PolicyCanvasLabToolbarDefaults.selection(in: defaults) ?? initialSelection"
      )
    )
    XCTAssertTrue(
      windowSource.contains("PolicyCanvasLabToolbarDefaults.algorithmSelection(in: defaults)")
    )
    XCTAssertTrue(
      windowSource.contains(
        "storedSampleSelectionRaw = PolicyCanvasLabToolbarDefaults.rawValue(for: newSelection)"
      )
    )
    XCTAssertTrue(
      windowSource.contains(
        "storedAlgorithmSelectionRaw = PolicyCanvasLabToolbarDefaults.rawValue(for: newSelection)"
      )
    )
  }

  func testLabResizeZoomDefaultsToScalingWithWindowSize() {
    let suiteName = "PolicyCanvasLabResizeZoomDefaults.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    defaults.removePersistentDomain(forName: suiteName)

    XCTAssertTrue(PolicyCanvasLabToolbarDefaults.scalesZoomOnResizeDefault)
    XCTAssertTrue(PolicyCanvasLabToolbarDefaults.scalesZoomOnResize(in: defaults))

    defaults.set(false, forKey: PolicyCanvasLabToolbarDefaults.scalesZoomOnResizeKey)
    XCTAssertFalse(PolicyCanvasLabToolbarDefaults.scalesZoomOnResize(in: defaults))
  }

  func testLabThemePickerIsWindowScopedAndDecoupledFromAppTheme() throws {
    let windowSource = try policyCanvasSourceFile(named: "PolicyCanvasLabWindowView.swift")
    let viewportSurfaceSource = try previewablePolicyCanvasSourceFile(
      named: "PolicyCanvasViewportSurface.swift"
    )
    let workspaceSource = try previewablePolicyCanvasSourceFile(
      named: "PolicyCanvasWorkspaceViews.swift"
    )
    let controlsSource = try policyCanvasSourceFile(named: "PolicyCanvasLabToolbarControls.swift")

    XCTAssertTrue(windowSource.contains("@AppStorage(PolicyCanvasLabThemeDefaults.modeKey)"))
    XCTAssertTrue(
      windowSource.contains(
        "private var windowThemeMode = PolicyCanvasLabThemeMode.defaultValue"
      )
    )
    XCTAssertTrue(
      windowSource.contains(
        "PolicyCanvasLabThemePicker(windowThemeMode: $windowThemeMode)"
      )
    )
    XCTAssertTrue(windowSource.contains(".preferredColorScheme(windowThemeMode.colorScheme)"))
    XCTAssertTrue(windowSource.contains("canvasColorScheme: windowThemeMode.colorScheme"))
    XCTAssertTrue(viewportSurfaceSource.contains("let canvasColorSchemeOverride: ColorScheme?"))
    XCTAssertTrue(
      viewportSurfaceSource.contains("canvasColorSchemeOverride: canvasColorSchemeOverride")
    )
    XCTAssertTrue(workspaceSource.contains("var canvasColorSchemeOverride: ColorScheme?"))
    XCTAssertTrue(workspaceSource.contains("canvasColorSchemeOverride ??"))
    XCTAssertFalse(windowSource.contains(".policyCanvasThemeScope()"))
    XCTAssertTrue(controlsSource.contains("Picker(\"Window theme\", selection: $windowThemeMode)"))
    XCTAssertTrue(controlsSource.contains("PolicyCanvasLabThemeMode.allCases"))
    XCTAssertFalse(controlsSource.contains("PolicyCanvasThemeMode.allCases"))
    XCTAssertFalse(controlsSource.contains("Use App Theme"))
  }

  func testLabMinimapUsesClickViewportRecenteringMode() throws {
    let windowSource = try policyCanvasSourceFile(named: "PolicyCanvasLabWindowView.swift")
    let viewportSurfaceSource = try previewablePolicyCanvasSourceFile(
      named: "PolicyCanvasViewportSurface.swift"
    )
    let minimapSource = try previewablePolicyCanvasSourceFile(
      named: "PolicyCanvasMinimapOverlay.swift"
    )

    XCTAssertTrue(
      windowSource.contains(
        "minimapCenteringMode: .clickViewport"
      )
    )
    XCTAssertTrue(
      viewportSurfaceSource.contains(
        "let minimapCenteringModeOverride: PolicyCanvasMinimapCenteringMode?"
      )
    )
    XCTAssertTrue(
      minimapSource.contains(
        "let minimapCenteringModeOverride: PolicyCanvasMinimapCenteringMode?"
      )
    )
    XCTAssertTrue(
      minimapSource.contains(
        "minimapCenteringModeOverride ?? storedMinimapCenteringMode"
      )
    )
  }

  func testLabHidesEdgeLegend() throws {
    let windowSource = try policyCanvasSourceFile(named: "PolicyCanvasLabWindowView.swift")
    let viewportSurfaceSource = try previewablePolicyCanvasSourceFile(
      named: "PolicyCanvasViewportSurface.swift"
    )
    let overlaySource = try previewablePolicyCanvasSourceFile(
      named: "PolicyCanvasViewportOverlayModifier.swift"
    )

    XCTAssertTrue(windowSource.contains("showsEdgeLegend: false"))
    XCTAssertTrue(viewportSurfaceSource.contains("let showsEdgeLegend: Bool"))
    XCTAssertTrue(overlaySource.contains("let showsEdgeLegend: Bool"))
    XCTAssertTrue(overlaySource.contains("if showsEdgeLegend"))
    XCTAssertTrue(overlaySource.contains("PolicyCanvasEdgeKindLegend()"))
  }

  @MainActor
  func testPolicyGraphWrapsAllNodesInOneNamedContainerGroup() throws {
    let sample = try XCTUnwrap(PolicyCanvasLabSamples.sample(id: "extreme"))
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.policyGroupTitle = sample.name
    viewModel.load(document: sample.document, simulation: nil, audit: nil)
    viewModel.reflowLayout(preserveManualAnchors: false, force: true)

    XCTAssertEqual(viewModel.groups.count, 1)
    let container = try XCTUnwrap(viewModel.groups.first)
    XCTAssertEqual(container.title, sample.name)
    XCTAssertFalse(viewModel.nodes.isEmpty)
    for node in viewModel.nodes {
      XCTAssertTrue(
        container.frame.contains(policyCanvasNodeFrame(node)),
        "node \(node.id) sits outside the container group"
      )
    }
  }

  func testLabWindowExposesLeadingReformatToolbarButton() throws {
    let windowSource = try policyCanvasSourceFile(named: "PolicyCanvasLabWindowView.swift")

    XCTAssertTrue(windowSource.contains("ToolbarItem(placement: .navigation)"))
    XCTAssertTrue(windowSource.contains("systemName: \"arrow.clockwise\""))
    XCTAssertTrue(windowSource.contains("reformatRequestID += 1"))
  }

  func testLabViewportSurfaceForcesEngineLayoutReflow() throws {
    let windowSource = try policyCanvasSourceFile(named: "PolicyCanvasLabWindowView.swift")
    let surfaceSource = try previewablePolicyCanvasSourceFile(
      named: "PolicyCanvasViewportSurface.swift"
    )

    XCTAssertTrue(windowSource.contains("forcesEngineLayout: true"))
    XCTAssertTrue(windowSource.contains("reformatRequest: reformatRequestID"))
    XCTAssertTrue(surfaceSource.contains("let forcesEngineLayout: Bool"))
    XCTAssertTrue(
      surfaceSource.contains("requestAtomicReflow(preserveManualAnchors: false, force: true)")
    )
  }

  func testStandaloneLabHostDisablesWritingToolsEligibilityChecks() throws {
    let appSource = try policyCanvasLabHostSourceFile(
      named: "HarnessMonitorPolicyCanvasLabApp.swift"
    )

    XCTAssertTrue(appSource.contains(".writingToolsBehavior(.disabled)"))
    XCTAssertTrue(appSource.contains(".restorationBehavior(.disabled)"))
    XCTAssertTrue(appSource.contains("@NSApplicationDelegateAdaptor"))
    XCTAssertTrue(appSource.contains("shouldRestoreApplicationState"))
    XCTAssertTrue(appSource.contains("shouldSaveApplicationState"))
  }

  @MainActor
  func testRequestAtomicReflowSignalsWithoutMutatingNodes() throws {
    let viewModel = PolicyCanvasViewModel.sample()
    let before = viewModel.nodes.map(\.position)
    XCTAssertNil(viewModel.atomicReflowRequest)

    viewModel.requestAtomicReflow(preserveManualAnchors: false, force: true)
    let request = try XCTUnwrap(viewModel.atomicReflowRequest)
    XCTAssertEqual(request.id, 1)
    XCTAssertFalse(request.preserveManualAnchors)
    XCTAssertTrue(request.force)
    // Raising the request must never move nodes: the viewport routes the planned
    // layout off-main and only then commits, so requesting is side-effect free.
    XCTAssertEqual(viewModel.nodes.map(\.position), before)

    viewModel.requestAtomicReflow()
    let second = try XCTUnwrap(viewModel.atomicReflowRequest)
    XCTAssertEqual(second.id, 2)
    XCTAssertTrue(second.preserveManualAnchors)
    XCTAssertTrue(second.force)
    // The signal is monotonic and never cleared, so servicing it cannot flip the
    // observed id and cancel the in-flight reflow before it commits.
    XCTAssertEqual(viewModel.atomicReflowRequest?.id, 2)
  }

  @MainActor
  func testForcedReformatIsDeterministicForExtremePolicy() throws {
    let sample = try XCTUnwrap(PolicyCanvasLabSamples.sample(id: "extreme"))
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: sample.document, simulation: nil, audit: nil)

    viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    let firstPositions = nodePositionsByID(viewModel)
    let firstGroups = groupFramesByID(viewModel)
    let firstRoutingHints = viewModel.routingHints

    viewModel.reflowLayout(preserveManualAnchors: false, force: true)

    XCTAssertEqual(nodePositionsByID(viewModel), firstPositions)
    XCTAssertEqual(groupFramesByID(viewModel), firstGroups)
    XCTAssertEqual(viewModel.routingHints, firstRoutingHints)
  }

  @MainActor
  func testExtremeGalaxyRejectsDetachedPrecomputedRouteFastPath() throws {
    let sample = try XCTUnwrap(PolicyCanvasLabSamples.sample(id: "extreme-galaxy"))
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: sample.document, simulation: nil, audit: nil)

    viewModel.reflowLayout(preserveManualAnchors: false, force: true)

    XCTAssertNil(viewModel.precomputedRoutes)
  }

  @MainActor
  func testProductionAndLabForcedDefaultReformatMatch() throws {
    let sample = try XCTUnwrap(PolicyCanvasLabSamples.sample(id: "default"))
    let productionViewModel = PolicyCanvasViewModel.liveStartupState(
      document: sample.document,
      simulation: nil,
      audit: nil,
      activeCanvasId: "default"
    )
    let labViewModel = PolicyCanvasViewModel.liveStartupState(
      document: sample.document,
      simulation: nil,
      audit: nil,
      activeCanvasId: nil,
      policyGroupTitle: sample.name
    )

    productionViewModel.reflowLayout(force: true)
    labViewModel.reflowLayout(preserveManualAnchors: false, force: true)

    XCTAssertEqual(nodePositionsByID(productionViewModel), nodePositionsByID(labViewModel))
    XCTAssertEqual(groupFramesByID(productionViewModel), groupFramesByID(labViewModel))
    XCTAssertEqual(productionViewModel.routingHints, labViewModel.routingHints)
  }

  @MainActor
  func testPlannedReflowGraphPredictsReflowCommitWithoutMutating() throws {
    let sample = try XCTUnwrap(PolicyCanvasLabSamples.sample(id: "extreme"))
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: sample.document, simulation: nil, audit: nil)
    let seeds = Dictionary(uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.position) })

    let graph = try XCTUnwrap(
      viewModel.plannedReflowGraph(preserveManualAnchors: false, force: true)
    )
    XCTAssertFalse(graph.nodes.isEmpty)
    // Planning the layout must leave the live model untouched.
    for node in viewModel.nodes {
      XCTAssertEqual(node.position, seeds[node.id], "planning moved \(node.id)")
    }

    // Committing reproduces the planned layout exactly, so routes computed from
    // the plan stay valid for the published nodes (the basis for atomic reveal).
    viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    let plannedByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.position) })
    for node in viewModel.nodes {
      XCTAssertEqual(node.position, plannedByID[node.id], "commit diverged from plan for \(node.id)")
    }
  }

  func testReformatTriggersUseAtomicReflow() throws {
    let surfaceSource = try previewablePolicyCanvasSourceFile(
      named: "PolicyCanvasViewportSurface.swift"
    )
    let chromeSource = try previewablePolicyCanvasSourceFile(named: "PolicyCanvasChromeViews.swift")
    let layoutSource = try previewablePolicyCanvasSourceFile(named: "PolicyCanvasView+Layout.swift")
    let dispatcherSource = try previewablePolicyCanvasSourceFile(
      named: "PolicyCanvasViewport+Dispatchers.swift"
    )

    // Lab and production Reformat both force the engine layout, but lab strips
    // manual anchors so algorithm comparisons always start from the same graph.
    XCTAssertTrue(
      surfaceSource.contains("requestAtomicReflow(preserveManualAnchors: false, force: true)")
    )
    XCTAssertFalse(surfaceSource.contains("viewModel.reflowLayout("))
    XCTAssertTrue(chromeSource.contains("viewModel.requestAtomicReflow()"))
    XCTAssertTrue(layoutSource.contains("viewModel.requestAtomicReflow()"))
    XCTAssertTrue(dispatcherSource.contains("viewModel.requestAtomicReflow()"))
    XCTAssertFalse(chromeSource.contains("viewModel.reflowLayout()"))
  }

  func testViewportServicesAtomicReflowAtomically() throws {
    let workspaceSource = try previewablePolicyCanvasSourceFile(
      named: "PolicyCanvasWorkspaceViews.swift"
    )
    let atomicSource = try previewablePolicyCanvasSourceFile(
      named: "PolicyCanvasViewport+AtomicReflow.swift"
    )

    XCTAssertTrue(
      workspaceSource.contains(
        ".onChange(of: viewModel.atomicReflowRequest?.id, initial: false)"
      )
    )
    XCTAssertTrue(atomicSource.contains("func performAtomicReflow("))
    XCTAssertTrue(atomicSource.contains("viewModel.atomicReflowRequest"))
    XCTAssertTrue(atomicSource.contains("plannedReflowGraph("))
    XCTAssertTrue(atomicSource.contains("routeWorkerInstance().compute(input: routeInput)"))
    // The commit publishes positions WITHOUT an async route request so the
    // precomputed routes reveal together with the nodes in a single frame.
    XCTAssertTrue(atomicSource.contains("requestsRouteComputation: false"))
  }

  @MainActor
  private func nodePositionsByID(
    _ viewModel: PolicyCanvasViewModel
  ) -> [String: CGPoint] {
    Dictionary(uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.position) })
  }

  @MainActor
  private func groupFramesByID(
    _ viewModel: PolicyCanvasViewModel
  ) -> [String: CGRect] {
    Dictionary(uniqueKeysWithValues: viewModel.groups.map { ($0.id, $0.frame) })
  }

  private func policyCanvasSourceFile(named name: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorPolicyCanvas")
      .appendingPathComponent(name)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  private func policyCanvasLabHostSourceFile(named name: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorPolicyCanvasLabHost")
      .appendingPathComponent(name)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  private func previewablePolicyCanvasSourceFile(named name: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor/Sources/HarnessMonitorUIPreviewable/Views/PolicyCanvas"
      )
      .appendingPathComponent(name)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
