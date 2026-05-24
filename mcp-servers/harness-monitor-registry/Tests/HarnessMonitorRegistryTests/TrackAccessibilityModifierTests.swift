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

  @Test("configure publishes geometry-based screen coordinates for visible tracked elements")
  @MainActor
  func configurePublishesGeometryBasedScreenCoordinates() async {
    let registry = AccessibilityRegistry()
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
    let view = TrackAccessibilityNSView(frame: NSRect(x: 40, y: 24, width: 120, height: 36))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    host.addSubview(view)
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()

    view.configure(
      elementID: "workspace.geometry",
      kind: .button,
      label: "Geometry",
      value: nil,
      hint: nil,
      windowID: nil,
      enabled: true,
      semanticActions: .none,
      semanticActionSink: nil,
      registry: registry
    )

    let element = await waitForElement(identifier: "workspace.geometry", registry: registry)
    let expectedFrame = RegistryRect(window.convertToScreen(view.convert(view.bounds, to: nil)))
    #expect(element?.frame == expectedFrame)
  }

  @Test("identical configure calls skip republish so dense panes do not churn")
  @MainActor
  func identicalConfigureCallsSkipRepublish() async {
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

    _ = await waitForElement(identifier: "workspace.refresh", registry: registry)
    let baselineQueries = frameQueryCount

    for _ in 0..<3 {
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
    }

    for _ in 0..<6 {
      await Task.yield()
    }

    #expect(frameQueryCount == baselineQueries)
  }

  @Test("rapid layout passes are throttled so dense panes do not republish per frame")
  @MainActor
  func rapidLayoutPassesAreThrottled() async {
    let registry = AccessibilityRegistry()
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
    let view = TrackAccessibilityNSView(frame: NSRect(x: 40, y: 24, width: 120, height: 36))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    host.addSubview(view)
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()

    var frameQueryCount = 0
    view.accessibilityFrameProviderOverride = { trackedView in
      frameQueryCount += 1
      return window.convertToScreen(trackedView.convert(trackedView.bounds, to: nil))
    }

    view.configure(
      elementID: "workspace.layout-throttle",
      kind: .button,
      label: "Layout Throttled",
      value: nil,
      hint: nil,
      windowID: nil,
      enabled: true,
      semanticActions: .none,
      semanticActionSink: nil,
      registry: registry
    )
    _ = await waitForElement(identifier: "workspace.layout-throttle", registry: registry)
    let baselineQueries = frameQueryCount

    // Simulate a burst of layout passes (e.g. 60Hz scroll). Each call must NOT
    // spawn a publish Task while inside the 120ms throttle window.
    for _ in 0..<10 {
      view.layout()
    }
    for _ in 0..<6 {
      await Task.yield()
    }

    #expect(frameQueryCount - baselineQueries <= 1)
  }

  @Test("didUpdate clears tracked elements once scrolling clips them fully off-screen")
  @MainActor
  func didUpdateClearsTrackedElementsWhenScrollingClipsThemOffScreen() async {
    let registry = AccessibilityRegistry()
    let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 640))
    let view = TrackAccessibilityNSView(frame: NSRect(x: 24, y: 24, width: 120, height: 36))
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    documentView.addSubview(view)
    scrollView.documentView = documentView
    window.contentView = scrollView
    window.layoutIfNeeded()
    documentView.layoutSubtreeIfNeeded()

    view.configure(
      elementID: "workspace.scrolled-away",
      kind: .button,
      label: "Scrolled Away",
      value: nil,
      hint: nil,
      windowID: nil,
      enabled: true,
      semanticActions: .none,
      semanticActionSink: nil,
      registry: registry
    )

    #expect(
      await waitUntil {
        await registry.element(identifier: "workspace.scrolled-away") != nil
      }
    )

    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 120))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
    try? await Task.sleep(for: .milliseconds(850))

    #expect(
      await waitUntil {
        await registry.element(identifier: "workspace.scrolled-away") == nil
      }
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

  @MainActor
  private func waitUntil(
    maxTurns: Int = 20,
    _ predicate: @escaping @MainActor () async -> Bool
  ) async -> Bool {
    for _ in 0..<maxTurns {
      if await predicate() {
        return true
      }
      await Task.yield()
    }
    return await predicate()
  }
}
