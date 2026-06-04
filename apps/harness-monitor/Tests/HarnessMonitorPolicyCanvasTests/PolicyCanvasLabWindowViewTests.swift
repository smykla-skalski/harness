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
