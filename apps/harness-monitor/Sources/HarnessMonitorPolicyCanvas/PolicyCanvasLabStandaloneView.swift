import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

public struct PolicyCanvasLabStandaloneView: View {
  private let initialSelection: PolicyCanvasLabSelection
  private let fixtureDocument: TaskBoardPolicyPipelineDocument?

  public init(
    initialSelection: PolicyCanvasLabSelection = .sample(PolicyCanvasLabSamples.defaultSelectionID),
    fixtureDocument: TaskBoardPolicyPipelineDocument? =
      PolicyCanvasLabSnapshotSupport.fixtureDocument()
  ) {
    self.initialSelection = initialSelection
    self.fixtureDocument = fixtureDocument
  }

  public var body: some View {
    PolicyCanvasLabWindowView(
      initialSelection: initialSelection,
      fixtureDocument: fixtureDocument
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
