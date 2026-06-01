import AppKit
import HarnessMonitorKit
import SwiftUI
import Testing

@testable import HarnessMonitor
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas lab picker runtime")
struct PolicyCanvasLabPickerRuntimeTests {
  @MainActor
  @Test("changing the lab-style sample selection updates the rendered canvas document")
  func changingSampleSelectionUpdatesRenderedCanvasDocument() async throws {
    let frame = CGRect(x: 0, y: 0, width: 1_400, height: 900)
    let host = NSHostingView(
      rootView: PolicyCanvasLabPickerHarness(selection: .sample("minimal"))
    )
    let window = NSWindow(
      contentRect: frame,
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    host.frame = frame
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()

    #expect(
      await waitUntil {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let documentView = descendant(of: host, as: PolicyCanvasNativeDocumentView.self) else {
          return false
        }
        let nodeIDs = Set(documentView.hostedState.snapshot.viewModel.nodes.map(\.id))
        return nodeIDs.contains("entry") && !nodeIDs.contains("router")
      }
    )

    host.rootView = PolicyCanvasLabPickerHarness(selection: .sample("branching"))
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()

    #expect(
      await waitUntil(timeout: .seconds(2)) {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let documentView = descendant(of: host, as: PolicyCanvasNativeDocumentView.self) else {
          return false
        }
        let nodeIDs = Set(documentView.hostedState.snapshot.viewModel.nodes.map(\.id))
        return nodeIDs.contains("router") && !nodeIDs.contains("entry")
      }
    )
  }
}

private struct PolicyCanvasLabPickerRenderedSnapshot: Equatable {
  let document: TaskBoardPolicyPipelineDocument?
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
}

private struct PolicyCanvasLabPickerHarness: View {
  let selection: PolicyCanvasLabSelection

  var body: some View {
    let renderedSnapshot = snapshot(for: selection)
    PolicyCanvasViewportSurface(
      document: renderedSnapshot.document,
      simulation: renderedSnapshot.simulation,
      audit: renderedSnapshot.audit
    )
  }

  private func snapshot(for selection: PolicyCanvasLabSelection) -> PolicyCanvasLabPickerRenderedSnapshot {
    switch selection {
    case .live:
      return PolicyCanvasLabPickerRenderedSnapshot(
        document: nil,
        simulation: nil,
        audit: nil
      )
    case .sample(let id):
      guard let sample = PolicyCanvasLabSamples.sample(id: id) else {
        return PolicyCanvasLabPickerRenderedSnapshot(
          document: nil,
          simulation: nil,
          audit: nil
        )
      }
      return PolicyCanvasLabPickerRenderedSnapshot(
        document: sample.document,
        simulation: nil,
        audit: nil
      )
    }
  }
}

@MainActor
private func descendant<ViewType: NSView>(
  of root: NSView,
  as type: ViewType.Type
) -> ViewType? {
  if let typedRoot = root as? ViewType {
    return typedRoot
  }
  for subview in root.subviews {
    if let match = descendant(of: subview, as: type) {
      return match
    }
  }
  return nil
}

@MainActor
private func waitUntil(
  timeout: Duration = .seconds(1),
  interval: Duration = .milliseconds(10),
  _ predicate: @escaping @Sendable @MainActor () -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while clock.now < deadline {
    if await MainActor.run(resultType: Bool.self, body: predicate) {
      return true
    }
    await Task.yield()
    try? await Task.sleep(for: interval)
  }
  return await MainActor.run(resultType: Bool.self, body: predicate)
}
