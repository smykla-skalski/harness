import AppKit
import Testing
@testable import HarnessMonitorRegistry

@Suite("TrackAccessibilityModifier")
struct TrackAccessibilityModifierTests {
  @Test("configure defers accessibility frame resolution")
  @MainActor
  func configureDefersAccessibilityFrameResolution() async {
    let registry = AccessibilityRegistry()
    let view = TrackAccessibilityNSView()
    let publishedFrame = NSRect(x: 12, y: 24, width: 120, height: 36)
    var frameQueryCount = 0
    view.accessibilityFrameProviderOverride = { _ in
      frameQueryCount += 1
      return publishedFrame
    }

    view.configure(
      elementID: "workspace.refresh",
      kind: .button,
      label: "Refresh workspace",
      value: nil,
      hint: nil,
      windowID: 41,
      enabled: true,
      semanticActions: .none,
      semanticActionSink: nil,
      registry: registry
    )

    #expect(frameQueryCount == 0)

    let element = await waitForElement(
      identifier: "workspace.refresh",
      registry: registry
    )
    #expect(frameQueryCount > 0)
    #expect(
      element
        == RegistryElement(
          identifier: "workspace.refresh",
          label: "Refresh workspace",
          kind: .button,
          actions: [],
          frame: RegistryRect(publishedFrame),
          windowID: 41,
          enabled: true
        )
    )
  }

  @MainActor
  private func waitForElement(
    identifier: String,
    registry: AccessibilityRegistry,
    maxTurns: Int = 10
  ) async -> RegistryElement? {
    for _ in 0..<maxTurns {
      if let element = await registry.element(identifier: identifier) {
        return element
      }
      await Task.yield()
    }
    return await registry.element(identifier: identifier)
  }
}
