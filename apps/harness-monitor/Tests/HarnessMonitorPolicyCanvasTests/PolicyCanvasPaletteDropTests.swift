import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas palette drop placement")
@MainActor
struct PolicyCanvasPaletteDropTests {
  @Test("first palette drop lands at the initial anchor")
  func firstDropAtInitialAnchor() {
    let viewModel = makeEmptyCanvas()
    let first = viewModel.nextPaletteDropCenter()
    #expect(first == PolicyCanvasLayout.initialPaletteDropAnchor)
  }

  @Test("successive palette drops advance by the configured step")
  func successiveDropsAdvanceByStep() {
    let viewModel = makeEmptyCanvas()
    let step = PolicyCanvasLayout.paletteDropStep

    let first = viewModel.nextPaletteDropCenter()
    let second = viewModel.nextPaletteDropCenter()
    let third = viewModel.nextPaletteDropCenter()

    #expect(second.x == first.x + step)
    #expect(second.y == first.y + step)
    #expect(third.x == second.x + step)
    #expect(third.y == second.y + step)
  }

  @Test("multiple clicks on the palette button create non-overlapping nodes")
  func multipleClicksDoNotCollide() {
    let viewModel = makeEmptyCanvas()

    viewModel.createNode(kind: .source, at: viewModel.nextPaletteDropCenter())
    viewModel.createNode(kind: .condition, at: viewModel.nextPaletteDropCenter())
    viewModel.createNode(kind: .decision, at: viewModel.nextPaletteDropCenter())

    let frames = viewModel.nodes.map {
      CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize)
    }
    for leftIndex in frames.indices {
      for rightIndex in frames.index(after: leftIndex)..<frames.endIndex {
        #expect(!frames[leftIndex].intersects(frames[rightIndex]))
      }
    }
  }

  @Test("drop center skips frames already covered by existing nodes")
  func dropSkipsOccupiedSlots() {
    let occupier = PolicyCanvasNode(
      id: "existing",
      title: "Existing",
      kind: .source,
      position: CGPoint(
        x: PolicyCanvasLayout.initialPaletteDropAnchor.x - PolicyCanvasLayout.nodeSize.width / 2,
        y: PolicyCanvasLayout.initialPaletteDropAnchor.y - PolicyCanvasLayout.nodeSize.height / 2
      )
    )
    let viewModel = PolicyCanvasViewModel(
      nodes: [occupier],
      groups: [],
      edges: [],
      selection: nil,
      zoom: 1
    )

    let center = viewModel.nextPaletteDropCenter()
    let frame = CGRect(
      x: center.x - PolicyCanvasLayout.nodeSize.width / 2,
      y: center.y - PolicyCanvasLayout.nodeSize.height / 2,
      width: PolicyCanvasLayout.nodeSize.width,
      height: PolicyCanvasLayout.nodeSize.height
    )
    #expect(!frame.intersects(CGRect(origin: occupier.position, size: PolicyCanvasLayout.nodeSize)))
  }

  @Test("resetPaletteDropPlacement rewinds the cursor to the initial anchor")
  func resetRewindsAnchor() {
    let viewModel = makeEmptyCanvas()
    _ = viewModel.nextPaletteDropCenter()
    _ = viewModel.nextPaletteDropCenter()

    viewModel.resetPaletteDropPlacement()
    let next = viewModel.nextPaletteDropCenter()
    #expect(next == PolicyCanvasLayout.initialPaletteDropAnchor)
  }

  @Test("dropPalettePayloads still honors the explicit drop point")
  func dragDropHonorsExplicitPoint() {
    let viewModel = makeEmptyCanvas()
    let payload = viewModel.palettePayload(for: .source)
    let dropPoint = CGPoint(x: 720, y: 380)

    let dropped = viewModel.dropPalettePayloads([payload], at: dropPoint)
    #expect(dropped)

    let createdCenter = viewModel.nodes.last.map {
      CGPoint(
        x: $0.position.x + PolicyCanvasLayout.nodeSize.width / 2,
        y: $0.position.y + PolicyCanvasLayout.nodeSize.height / 2
      )
    }
    // dropPalettePayloads snaps to the grid, so check the gap is at most one
    // grid step in each axis.
    let dx = abs((createdCenter?.x ?? 0) - dropPoint.x)
    let dy = abs((createdCenter?.y ?? 0) - dropPoint.y)
    #expect(dx <= PolicyCanvasLayout.gridSize)
    #expect(dy <= PolicyCanvasLayout.gridSize)
  }

  @Test("dropPalettePayloads creates automation variants from list payloads")
  func dragDropCreatesAutomationVariant() {
    let viewModel = makeEmptyCanvas()
    let item = PolicyCanvasAutomationPaletteItem.ocrImages
    let payload = viewModel.palettePayload(for: item)

    let dropped = viewModel.dropPalettePayloads([payload], at: CGPoint(x: 360, y: 240))
    #expect(dropped)

    let node = viewModel.nodes.last
    #expect(node?.kind == item.nodeKind)
    #expect(node?.title == item.title)
    #expect(node?.subtitle == item.subtitle)
    #expect(node?.automationBinding == item.automationBinding)
  }

  @Test("content and safety automation presets create canonical if then else nodes")
  func contentAndSafetyAutomationVariantsUseIfThenElse() throws {
    let viewModel = makeEmptyCanvas()
    let migratedItems = PolicyCanvasAutomationPaletteItem.allCases.filter {
      $0.section == .content || $0.section == .safety
    }

    for item in migratedItems {
      viewModel.createAutomationNode(item: item, at: viewModel.nextPaletteDropCenter())
      let node = try #require(viewModel.nodes.last)
      #expect(node.kind == .ifThenElse, "\(item.rawValue) should author as if_then_else")
      #expect(node.policyKind?.discriminator == "if_then_else")
    }
  }

  @Test("review screenshot automation presets create dedicated node kinds")
  func reviewScreenshotAutomationVariantsUseDedicatedNodeKinds() throws {
    let viewModel = makeEmptyCanvas()
    let expectedKinds: [PolicyCanvasAutomationPaletteItem: PolicyCanvasNodeKind] = [
      .reviewScreenshotPaste: .reviewScreenshotPaste,
      .ocrImages: .ocrImage,
      .resolveReviewPullRequests: .resolveReviewPullRequests,
      .copyReviewPullRequestList: .copyReviewPullRequestList,
    ]

    for (item, expectedKind) in expectedKinds {
      viewModel.createAutomationNode(item: item, at: viewModel.nextPaletteDropCenter())
      let node = try #require(viewModel.nodes.last)
      #expect(
        node.kind == expectedKind,
        "\(item.rawValue) should author as \(expectedKind.rawValue)"
      )
      #expect(node.policyKind?.discriminator == expectedKind.rawValue)
    }
  }

  // MARK: - Helpers

  private func makeEmptyCanvas() -> PolicyCanvasViewModel {
    PolicyCanvasViewModel(
      nodes: [],
      groups: [],
      edges: [],
      selection: nil,
      zoom: 1
    )
  }
}
