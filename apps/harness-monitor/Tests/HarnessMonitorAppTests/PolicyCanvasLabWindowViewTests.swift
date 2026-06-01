import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import XCTest

@testable import HarnessMonitor

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
    let document = try XCTUnwrap(PolicyCanvasLabSamples.sample(id: "default-like")?.document)

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
    let document = try XCTUnwrap(PolicyCanvasLabSamples.sample(id: "default-like")?.document)

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

  func testStartupDefaultsRegisterUseAppThemeForPolicyCanvasThemeMode() {
    XCTAssertEqual(
      HarnessMonitorStartupRegistrationDefaults.values()[PolicyCanvasThemeDefaults.modeKey]
        as? String,
      PolicyCanvasThemeMode.defaultValue.rawValue
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
    let source = try appSourceFile(named: "PolicyCanvasLabWindowView.swift")

    XCTAssertTrue(source.contains("PolicyCanvasViewportSurface("))
    XCTAssertTrue(source.contains("forcesAutoArrange: true"))
  }

  func testLabToolbarExposesGroupsToggleBeforeAlgorithmPickers() throws {
    let windowSource = try appSourceFile(named: "PolicyCanvasLabWindowView.swift")
    let controlsSource = try appSourceFile(named: "PolicyCanvasLabToolbarControls.swift")

    XCTAssertTrue(windowSource.contains("@State private var includesGroupsInLayout = true"))
    XCTAssertTrue(
      windowSource.contains(
        "PolicyCanvasLabGroupsToggle(includesGroupsInLayout: $includesGroupsInLayout)"
      )
    )
    XCTAssertTrue(controlsSource.contains("Toggle(isOn: $includesGroupsInLayout)"))
    XCTAssertTrue(controlsSource.contains("Text(\"Groups\")"))
  }

  func testLabToolbarTextMenusUseSymmetricLabelPadding() throws {
    let windowSource = try appSourceFile(named: "PolicyCanvasLabWindowView.swift")
    let controlsSource = try appSourceFile(named: "PolicyCanvasLabToolbarControls.swift")

    XCTAssertTrue(
      windowSource.contains("PolicyCanvasLabToolbarTextMenuLabel(title: samplePickerTitle)")
    )
    XCTAssertTrue(
      controlsSource.contains(
        "PolicyCanvasLabToolbarTextMenuLabel(title: descriptor.stage.labToolbarLabel)"
      )
    )
    XCTAssertTrue(
      controlsSource.contains(".buttonStyle(PolicyCanvasLabToolbarTextMenuStyle())")
    )
    XCTAssertTrue(controlsSource.contains(".padding(.horizontal, chromePadding)"))
    XCTAssertTrue(controlsSource.contains(".padding(.vertical, chromePadding)"))
  }

  private func appSourceFile(named name: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitor/App")
      .appendingPathComponent(name)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
