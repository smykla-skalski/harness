import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas live startup")
@MainActor
struct PolicyCanvasBootstrapTests {
  @Test("live startup state loads the current policy pipeline instead of preview sample data")
  func liveStartupStateLoadsProvidedDocument() {
    let document = PreviewFixtures.policyCanvasPipelineDocument(revision: 23)
    let simulation = PreviewFixtures.policyCanvasSimulation(for: document)

    let viewModel = PolicyCanvasViewModel.liveStartupState(
      document: document,
      simulation: simulation,
      audit: nil
    )

    #expect(viewModel.backingDocument?.revision == 23)
    #expect(viewModel.latestSimulation?.revision == 23)
    #expect(viewModel.nodes.contains { $0.id == "action:router" })
    #expect(!viewModel.nodes.contains { $0.id == "policy-source" })
    #expect(viewModel.groups.contains { $0.id == "entry" })
    #expect(viewModel.viewportCenteringGeneration == 1)
  }

  @Test("live startup state stays empty until a policy pipeline is available")
  func liveStartupStateWithoutDocumentStaysEmpty() {
    let viewModel = PolicyCanvasViewModel.liveStartupState(
      document: nil,
      simulation: nil,
      audit: nil
    )

    #expect(viewModel.backingDocument == nil)
    #expect(viewModel.nodes.isEmpty)
    #expect(viewModel.groups.isEmpty)
    #expect(viewModel.edges.isEmpty)
    #expect(viewModel.isEmpty)
    #expect(viewModel.viewportCenteringGeneration == 0)
  }
}
