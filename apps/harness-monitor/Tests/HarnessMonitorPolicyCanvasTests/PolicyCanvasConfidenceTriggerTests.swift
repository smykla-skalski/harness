import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas

/// Phase 3 confidence auto-runner: the `confidenceTrigger` that replaced the
/// Simulate button fires on the clean->dirty edge (exactly like autosave) so a
/// drag firing `markDocumentDirty()` at ~60Hz still schedules one simulation.
@Suite("Policy canvas confidence auto-runner")
@MainActor
struct PolicyCanvasConfidenceTriggerTests {
  @Test("Confidence trigger fires on the clean-to-dirty edge, not on every edit")
  func confidenceTriggerFiresOnEdge() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    var fireCount = 0
    viewModel.confidenceTrigger = { fireCount += 1 }

    viewModel.markDocumentDirty()
    #expect(fireCount == 1)

    // Still dirty: a second edit flows into the already-scheduled debounce.
    viewModel.markDocumentDirty()
    #expect(fireCount == 1)

    // A save (or undo) returns the document to clean; the next edit re-arms.
    viewModel.documentDirty = false
    viewModel.markDocumentDirty()
    #expect(fireCount == 2)
  }

  @Test("Cancelling confidence evaluation clears the in-flight task")
  func cancelClearsConfidenceTask() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])

    viewModel.scheduleConfidenceEvaluation {}
    #expect(viewModel.confidenceTask != nil)

    viewModel.cancelConfidenceEvaluation()
    #expect(viewModel.confidenceTask == nil)
  }

  @Test("Confidence auto-run evaluates without cancelling autosave")
  func confidenceAutoRunEvaluatesWithoutCancellingAutosave() throws {
    let supportSource = try previewablePolicyCanvasSourceFile(named: "PolicyCanvasView+Support.swift")
    let actionsSource = try previewablePolicyCanvasSourceFile(named: "PolicyCanvasView+Actions.swift")

    #expect(supportSource.contains("evaluateConfidence()"))
    #expect(!supportSource.contains("simulate()"))
    #expect(actionsSource.contains("func simulate() {\n    runSimulation(cancelPendingAutosave: true)"))
    #expect(
      actionsSource.contains("func evaluateConfidence() {\n    runSimulation(cancelPendingAutosave: false)")
    )
    #expect(actionsSource.contains("if cancelPendingAutosave {\n      viewModel.cancelAutosave()"))
  }
}

private func previewablePolicyCanvasSourceFile(named fileName: String) throws -> String {
  let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  let monitorRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()
  let url = monitorRoot
    .appendingPathComponent("Sources/HarnessMonitorUIPreviewable/Views/PolicyCanvas")
    .appendingPathComponent(fileName)
  return try String(contentsOf: url, encoding: .utf8)
}
