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

  func testLabCanvasForcesAutoArrangeOnTheSingleElkLayoutPath() throws {
    let source = try policyCanvasSourceFile(named: "PolicyCanvasLabWindowView.swift")

    XCTAssertTrue(source.contains("PolicyCanvasViewportSurface("))
    XCTAssertTrue(source.contains("showsQualityInspection: showsQualityMetrics"))
    XCTAssertTrue(source.contains("forcesEngineLayout: true"))
    XCTAssertFalse(source.contains("PolicyCanvasLabAlgorithmPresetPicker"))
    XCTAssertFalse(source.contains("PolicyCanvasLabStageToolbar"))
  }

  @MainActor
  func testElkDefaultAppliesToSmallSamples() throws {
    let sample = try XCTUnwrap(PolicyCanvasLabSamples.sample(id: "default"))
    let viewModel = PolicyCanvasViewModel.liveStartupState(
      document: sample.document,
      simulation: nil,
      audit: nil,
      activeCanvasId: nil,
      policyGroupTitle: sample.name
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
    XCTAssertFalse(windowSource.contains("PolicyCanvasLabStageToolbar"))
    XCTAssertFalse(controlsSource.contains("struct PolicyCanvasLabStageToolbar"))
    XCTAssertFalse(windowSource.contains("ToolbarItemGroup(placement: .primaryAction)"))
    XCTAssertFalse(windowSource.contains(".sharedBackgroundVisibility(.automatic)"))
    XCTAssertFalse(controlsSource.contains("PolicyCanvasLabGroupsToggle"))
    XCTAssertFalse(controlsSource.contains("Toggle(isOn: $includesGroupsInLayout)"))
    XCTAssertFalse(controlsSource.contains("Text(\"Groups\")"))
  }

  func testLabDoesNotExposeAlgorithmPickers() throws {
    let windowSource = try policyCanvasSourceFile(named: "PolicyCanvasLabWindowView.swift")
    let controlsSource = try policyCanvasSourceFile(named: "PolicyCanvasLabToolbarControls.swift")

    XCTAssertFalse(windowSource.contains("PolicyCanvasLabAlgorithm"))
    XCTAssertFalse(controlsSource.contains("PolicyCanvasLabAlgorithm"))
    XCTAssertFalse(controlsSource.contains("PolicyCanvasAlgorithmPickerCatalog"))
  }

  func testLabToolbarTextMenusUseNativeButtonChromeOnly() throws {
    let windowSource = try policyCanvasSourceFile(named: "PolicyCanvasLabWindowView.swift")
    let controlsSource = try policyCanvasSourceFile(named: "PolicyCanvasLabToolbarControls.swift")

    XCTAssertTrue(
      windowSource.contains("PolicyCanvasLabToolbarTextMenuLabel(title: samplePickerTitle)")
    )
    XCTAssertTrue(windowSource.contains(".controlSize(.small)"))
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
      windowSource.contains("@AppStorage(PolicyCanvasLabToolbarDefaults.scalesZoomOnResizeKey)")
    )
    XCTAssertTrue(
      windowSource.contains(
        "PolicyCanvasLabToolbarDefaults.selection(in: defaults) ?? initialSelection"
      )
    )
    XCTAssertFalse(
      windowSource.contains("PolicyCanvasLabToolbarDefaults.algorithmSelection(in: defaults)")
    )
    XCTAssertTrue(
      windowSource.contains(
        "storedSampleSelectionRaw = PolicyCanvasLabToolbarDefaults.rawValue(for: newSelection)"
      )
    )
    XCTAssertFalse(windowSource.contains("algorithmSelectionKey"))
    XCTAssertFalse(windowSource.contains("storedAlgorithmSelectionRaw"))
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

  func testLabPrewarmDoesNotDuplicateTheSelectedStressSample() throws {
    let windowSource = try policyCanvasSourceFile(named: "PolicyCanvasLabWindowView.swift")

    XCTAssertTrue(
      windowSource.contains(
        "let priorityIDs = selectedSampleID == \"extreme-galaxy\" ? [] : [\"extreme-galaxy\"]"
      )
    )
    XCTAssertFalse(windowSource.contains("[selectedSampleID, \"extreme-galaxy\"]"))
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

  @MainActor
  func testExtremeGalaxyForcedEngineFirstPaintPrepStaysBelowOneSecond() throws {
    let sample = try XCTUnwrap(PolicyCanvasLabSamples.sample(id: "extreme-galaxy"))
    let start = Date()
    let viewModel = PolicyCanvasViewModel.liveStartupState(
      document: sample.document,
      simulation: nil,
      audit: nil,
      activeCanvasId: nil,
      policyGroupTitle: sample.name
    )
    let plannedGraph = try XCTUnwrap(
      viewModel.plannedReflowGraph(preserveManualAnchors: false, force: true)
    )
    let routeInput = PolicyCanvasRouteWorkerInput(
      graphGeneration: viewModel.routeComputationGeneration,
      nodes: plannedGraph.nodes,
      groups: plannedGraph.groups,
      edges: plannedGraph.edges,
      fontScale: 1,
      routingHints: plannedGraph.routingHints,
      precomputedRoutes: plannedGraph.precomputedRoutes,
      algorithmSelection: viewModel.algorithmSelection
    )
    let output = try XCTUnwrap(policyCanvasFastPrecomputedRouteOutput(input: routeInput))
    viewModel.commitPlannedReflowGraph(
      plannedGraph,
      preserveManualAnchors: false,
      force: true,
      requestsRouteComputation: false
    )
    let elapsedMs = Date().timeIntervalSince(start) * 1_000

    XCTAssertEqual(output.routes.count, plannedGraph.edges.count)
    XCTAssertFalse(output.visibleBounds.isNull)
    XCTAssertLessThan(elapsedMs, 1_000)
  }

  func testStandaloneLabHostPersistsWindowFrame() throws {
    let appSource = try policyCanvasLabHostSourceFile(
      named: "HarnessMonitorPolicyCanvasLabApp.swift"
    )

    XCTAssertTrue(appSource.contains(".writingToolsBehavior(.disabled)"))
    XCTAssertTrue(appSource.contains(".restorationBehavior(.disabled)"))
    XCTAssertTrue(appSource.contains("PolicyCanvasLabWindowFramePersistenceInstaller"))
    XCTAssertTrue(appSource.contains("PolicyCanvasLabWindowMetrics.frameDefaultsKey"))
    XCTAssertTrue(appSource.contains("PolicyCanvasLabWindowFrameStore.savedSize("))
    XCTAssertTrue(appSource.contains("PolicyCanvasLabWindowFrameStore.restoreFrame("))
    XCTAssertTrue(appSource.contains("PolicyCanvasLabWindowFrameStore.persistFrame("))
    XCTAssertTrue(appSource.contains("NSWindow.didEndLiveResizeNotification"))
    XCTAssertTrue(appSource.contains("NSWindow.didResizeNotification"))
    XCTAssertTrue(appSource.contains("NSWindow.didMoveNotification"))
    XCTAssertTrue(appSource.contains("NSWindow.willCloseNotification"))
    XCTAssertTrue(appSource.contains("configuredWindow?.inLiveResize == false"))
    XCTAssertFalse(appSource.contains(".restorationBehavior(.automatic)"))
    XCTAssertFalse(appSource.contains("setFrameAutosaveName"))
    XCTAssertFalse(appSource.contains("shouldRestoreApplicationState"))
    XCTAssertFalse(appSource.contains("shouldSaveApplicationState"))
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

  // The fast-path reveal reuses precomputed routes only while their terminals
  // still attach to the published node frames. Routes detached from a different
  // layout must be rejected so the canvas recomputes them instead of revealing
  // misaligned wires. extreme-galaxy used to be the detached fixture here, but
  // enabling ELK lab layouts made its routes attach (now asserted positively by
  // PolicyCanvasGraphQualityGateTests), so the guard is exercised directly with
  // a fixture that does not depend on any one sample's layout staying detached.
  func testDetachedPrecomputedRoutesAreRejected() {
    let nodeSize = PolicyCanvasLayout.nodeSize
    let targetX = nodeSize.width + 220
    let source = PolicyCanvasNode(id: "source", title: "Source", kind: .source, position: .zero)
    let target = PolicyCanvasNode(
      id: "target",
      title: "Target",
      kind: .decision,
      position: CGPoint(x: targetX, y: 0)
    )
    let edge = PolicyCanvasEdge(
      id: "edge-source-target",
      source: PolicyCanvasPortEndpoint(
        nodeID: source.id,
        portID: source.outputPorts[0].id,
        kind: .output
      ),
      target: PolicyCanvasPortEndpoint(
        nodeID: target.id,
        portID: target.inputPorts[0].id,
        kind: .input
      ),
      label: "review"
    )
    let nodes = [source, target]
    let edges = [edge]

    func layoutResult(routes: [String: PolicyCanvasEdgeRoute]) -> PolicyCanvasLayoutResult {
      PolicyCanvasLayoutResult(
        nodePositions: [source.id: source.position, target.id: target.position],
        groupFrames: [:],
        autoPlacedNodeIDs: [],
        metrics: PolicyCanvasLayoutMetrics(
          macroLayerCount: 0,
          crossGroupOrderViolations: 0,
          anchoredNodeCount: 0,
          edgeCrossingCount: 0,
          flowDirectionViolationCount: 0,
          averageEdgeLength: 0,
          edgeLengthVariance: 0,
          readabilityScore: 0
        ),
        routingHints: nil,
        precomputedRoutes: PolicyCanvasPrecomputedRouteSet(identity: "test", routes: routes)
      )
    }

    let midY = nodeSize.height / 2
    let attached = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: nodeSize.width, y: midY), CGPoint(x: targetX, y: midY)],
      labelPosition: CGPoint(x: targetX / 2, y: midY)
    )
    XCTAssertNotNil(
      policyCanvasAppliedPrecomputedRoutes(
        result: layoutResult(routes: [edge.id: attached]),
        nodes: nodes,
        edges: edges
      ),
      "routes whose terminals sit on the node frames must be accepted"
    )

    let detached = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: nodeSize.width, y: midY), CGPoint(x: 5000, y: 5000)],
      labelPosition: CGPoint(x: targetX / 2, y: midY)
    )
    XCTAssertNil(
      policyCanvasAppliedPrecomputedRoutes(
        result: layoutResult(routes: [edge.id: detached]),
        nodes: nodes,
        edges: edges
      ),
      "a route terminal that floats off its target frame must reject the fast path"
    )

    XCTAssertNil(
      policyCanvasAppliedPrecomputedRoutes(
        result: layoutResult(routes: [:]),
        nodes: nodes,
        edges: edges
      ),
      "a route set that does not cover every edge must reject the fast path"
    )
  }

  @MainActor
  func testProductionAndLabForcedDefaultReformatMatch() async throws {
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

    productionViewModel.reflowLayout(preserveManualAnchors: false, force: true)
    labViewModel.reflowLayout(preserveManualAnchors: false, force: true)

    XCTAssertEqual(nodePositionsByID(productionViewModel), nodePositionsByID(labViewModel))
    XCTAssertEqual(groupFramesByID(productionViewModel), groupFramesByID(labViewModel))
    XCTAssertEqual(productionViewModel.routingHints, labViewModel.routingHints)
    XCTAssertEqual(productionViewModel.precomputedRoutes, labViewModel.precomputedRoutes)
    let productionRoutes = await routeOutput(for: productionViewModel)
    let labRoutes = await routeOutput(for: labViewModel)
    XCTAssertEqual(productionRoutes.routes, labRoutes.routes)
    XCTAssertEqual(productionRoutes.labelPositions, labRoutes.labelPositions)
    XCTAssertEqual(productionRoutes.portVisibility, labRoutes.portVisibility)
    XCTAssertEqual(productionRoutes.portMarkerLayout, labRoutes.portMarkerLayout)
    XCTAssertEqual(productionRoutes.visibleBounds, labRoutes.visibleBounds)
    XCTAssertEqual(productionRoutes.contentSize, labRoutes.contentSize)
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
      XCTAssertEqual(
        node.position,
        plannedByID[node.id],
        "commit diverged from plan for \(node.id)"
      )
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

    let forcedReformatRequest =
      "requestAtomicReflow(preserveManualAnchors: false, force: true)"

    // Lab and production Reformat both force the engine layout and strip manual
    // anchors so they start from the same graph.
    XCTAssertTrue(
      surfaceSource.contains(forcedReformatRequest)
    )
    XCTAssertFalse(surfaceSource.contains("viewModel.reflowLayout("))
    XCTAssertTrue(chromeSource.contains("viewModel.\(forcedReformatRequest)"))
    XCTAssertTrue(layoutSource.contains("viewModel.\(forcedReformatRequest)"))
    XCTAssertTrue(dispatcherSource.contains("viewModel.\(forcedReformatRequest)"))
    XCTAssertFalse(chromeSource.contains("viewModel.requestAtomicReflow()"))
    XCTAssertFalse(layoutSource.contains("viewModel.requestAtomicReflow()"))
    XCTAssertFalse(dispatcherSource.contains("viewModel.requestAtomicReflow()"))
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

  @MainActor
  private func routeOutput(
    for viewModel: PolicyCanvasViewModel
  ) async -> PolicyCanvasRouteWorkerOutput {
    await PolicyCanvasRouteWorker(router: PolicyCanvasVisibilityRouter()).compute(
      input: PolicyCanvasRouteWorkerInput(
        graphGeneration: viewModel.routeComputationGeneration,
        nodes: viewModel.nodes,
        groups: viewModel.groups,
        edges: viewModel.edges,
        fontScale: 1,
        routingHints: viewModel.routingHints,
        precomputedRoutes: viewModel.precomputedRoutes,
        algorithmSelection: viewModel.algorithmSelection
      )
    )
  }
}
