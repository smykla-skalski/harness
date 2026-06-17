import AppKit
import HarnessMonitorKit
import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

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
        guard
          let documentView = descendant(of: host, as: PolicyCanvasNativeDocumentView.self)
        else {
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
      await waitUntil(timeout: .seconds(4)) {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard
          let documentView = descendant(of: host, as: PolicyCanvasNativeDocumentView.self)
        else {
          return false
        }
        let nodeIDs = Set(documentView.hostedState.snapshot.viewModel.nodes.map(\.id))
        return nodeIDs.contains("router") && !nodeIDs.contains("entry")
      }
    )
  }

  @MainActor
  @Test("changing an internal algorithm selection does not move ELK layout positions")
  func changingAlgorithmSelectionDoesNotMoveElkLayoutPositions() async throws {
    let frame = CGRect(x: 0, y: 0, width: 1_400, height: 900)
    let host = NSHostingView(
      rootView: PolicyCanvasLabPickerHarness(
        selection: .sample("default"),
        algorithmSelection: .referenceRouting
      )
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
      await waitUntil(timeout: .seconds(3)) {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        return nodePositions(in: host).count >= 16
      }
    )

    let harnessPositions = nodePositions(in: host)
    #expect(!harnessPositions.isEmpty)

    host.rootView = PolicyCanvasLabPickerHarness(
      selection: .sample("default"),
      algorithmSelection: .referencePure
    )
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()

    #expect(
      await waitUntil(timeout: .seconds(3)) {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        return nodePositions(in: host).count >= 16
      }
    )
    #expect(nodePositions(in: host) == harnessPositions)
  }

  @MainActor
  @Test("changing the lab sample replaces the rendered document")
  func changingSampleReplacesRenderedDocument() async throws {
    let frame = CGRect(x: 0, y: 0, width: 1_400, height: 900)
    let host = NSHostingView(
      rootView: PolicyCanvasLabPickerHarness(
        selection: .sample("default"),
        algorithmSelection: .referenceRouting
      )
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
      await waitUntil(timeout: .seconds(3)) {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        return nodePositions(in: host).count >= 16
      }
    )

    host.rootView = PolicyCanvasLabPickerHarness(
      selection: .sample("minimal")
    )
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()

    #expect(
      await waitUntil(timeout: .seconds(4)) {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        let ids = nodeIDs(in: host)
        return ids == ["entry", "finish"]
      }
    )
  }

  @MainActor
  @Test("the lab window restores persisted sample and ignores legacy algorithm toolbar selections")
  func labWindowRestoresPersistedSampleAndIgnoresLegacyAlgorithmSelection() async throws {
    let suiteName = "PolicyCanvasLabPickerRuntimeTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let sampleKey = "policyCanvasLabSampleSelection"
    let algorithmKey = "policyCanvasLabAlgorithmSelection"

    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.removePersistentDomain(forName: suiteName)
    defaults.set("minimal", forKey: sampleKey)
    defaults.set(PolicyCanvasAlgorithmSelection.referencePure.cacheIdentity, forKey: algorithmKey)

    let frame = CGRect(x: 0, y: 0, width: 1_400, height: 900)
    let host = NSHostingView(
      rootView: PolicyCanvasLabWindowView(
        fixtureDocument: nil,
        defaults: defaults
      )
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
      await waitUntil(timeout: .seconds(4)) {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard
          let documentView = descendant(of: host, as: PolicyCanvasNativeDocumentView.self)
        else {
          return false
        }
        let viewModel = documentView.hostedState.snapshot.viewModel
        let ids = Set(viewModel.nodes.map(\.id))
        return ids == ["entry", "finish"]
          && viewModel.algorithmSelection == .referenceRouting
      }
    )
  }

  @MainActor
  @Test("the lab window keeps sample node groups in the rendered canvas")
  func labWindowKeepsSampleNodeGroupsInRenderedCanvas() async throws {
    let frame = CGRect(x: 0, y: 0, width: 1_400, height: 900)
    let host = NSHostingView(
      rootView: PolicyCanvasLabWindowView(
        initialSelection: .sample("default"),
        fixtureDocument: nil
      )
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
      await waitUntil(timeout: .seconds(3)) {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let snapshot = groupingSnapshot(in: host) else {
          return false
        }
        return !snapshot.groupIDs.isEmpty && snapshot.nodeGroupIDs.contains { $0 != nil }
      }
    )
  }

  @MainActor
  @Test("the lab window defaults to proportional resize zoom")
  func labWindowDefaultsToProportionalResizeZoom() async throws {
    let suiteName = "PolicyCanvasLabPickerRuntimeTests.resizeZoom.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)

    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let scrollView = try await labWindowScrollView(defaults: defaults)
    #expect(scrollView.viewportResizeZoomBehavior == .scaleProportionally)

    defaults.set(false, forKey: PolicyCanvasLabToolbarDefaults.scalesZoomOnResizeKey)

    let optedOutScrollView = try await labWindowScrollView(defaults: defaults)
    #expect(optedOutScrollView.viewportResizeZoomBehavior == .preserveZoom)
  }
}

private struct PolicyCanvasLabPickerRenderedSnapshot: Equatable {
  let document: TaskBoardPolicyPipelineDocument?
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
}

private struct PolicyCanvasLabPickerHarness: View {
  let selection: PolicyCanvasLabSelection
  let algorithmSelection: PolicyCanvasAlgorithmSelection

  init(
    selection: PolicyCanvasLabSelection,
    algorithmSelection: PolicyCanvasAlgorithmSelection = .referenceRouting
  ) {
    self.selection = selection
    self.algorithmSelection = algorithmSelection
  }

  var body: some View {
    let renderedSnapshot = snapshot(for: selection)
    PolicyCanvasViewportSurface(
      document: renderedSnapshot.document,
      simulation: renderedSnapshot.simulation,
      audit: renderedSnapshot.audit,
      algorithmSelection: algorithmSelection
    )
  }

  private func snapshot(
    for selection: PolicyCanvasLabSelection
  ) -> PolicyCanvasLabPickerRenderedSnapshot {
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

private struct RenderedCanvasGroupingSnapshot: Equatable {
  let nodeIDs: Set<String>
  let nodeGroupIDs: [String?]
  let groupIDs: [String]
}

@MainActor
private func labWindowScrollView(
  defaults: UserDefaults
) async throws -> PolicyCanvasNativeScrollView {
  let frame = CGRect(x: 0, y: 0, width: 1_400, height: 900)
  let host = NSHostingView(
    rootView: PolicyCanvasLabWindowView(
      fixtureDocument: nil,
      defaults: defaults
    )
  )
  let window = NSWindow(
    contentRect: frame,
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
  )

  host.frame = frame
  window.contentView = host
  window.layoutIfNeeded()
  host.layoutSubtreeIfNeeded()

  let didMountScrollView = await waitUntil(timeout: .seconds(3)) {
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    return descendant(of: host, as: PolicyCanvasNativeScrollView.self) != nil
  }
  let scrollView = try #require(descendant(of: host, as: PolicyCanvasNativeScrollView.self))
  #expect(didMountScrollView)

  window.orderOut(nil)
  window.contentView = nil
  return scrollView
}

@MainActor
private func nodePositions(in root: NSView) -> [String: CGPoint] {
  guard let documentView = descendant(of: root, as: PolicyCanvasNativeDocumentView.self) else {
    return [:]
  }
  return Dictionary(
    uniqueKeysWithValues: documentView.hostedState.snapshot.viewModel.nodes.map {
      ($0.id, $0.position)
    }
  )
}

@MainActor
private func nodeIDs(in root: NSView) -> Set<String> {
  guard let documentView = descendant(of: root, as: PolicyCanvasNativeDocumentView.self) else {
    return []
  }
  return Set(documentView.hostedState.snapshot.viewModel.nodes.map(\.id))
}

@MainActor
private func groupingSnapshot(in root: NSView) -> RenderedCanvasGroupingSnapshot? {
  guard let documentView = descendant(of: root, as: PolicyCanvasNativeDocumentView.self) else {
    return nil
  }
  let viewModel = documentView.hostedState.snapshot.viewModel
  return RenderedCanvasGroupingSnapshot(
    nodeIDs: Set(viewModel.nodes.map(\.id)),
    nodeGroupIDs: viewModel.nodes.map(\.groupID),
    groupIDs: viewModel.groups.map(\.id)
  )
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
