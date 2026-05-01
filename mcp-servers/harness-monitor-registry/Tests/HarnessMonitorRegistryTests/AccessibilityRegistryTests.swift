import AppKit
import Testing
@testable import HarnessMonitorRegistry

@Suite("AccessibilityRegistry")
struct AccessibilityRegistryTests {
  @Test("registers and retrieves elements by identifier")
  func registerAndRetrieve() async {
    let registry = AccessibilityRegistry()
    let element = RegistryElement(
      identifier: "sidebar.search",
      kind: .textField,
      frame: RegistryRect(x: 10, y: 20, width: 200, height: 28)
    )
    await registry.registerElement(element)
    let fetched = await registry.element(identifier: "sidebar.search")
    #expect(fetched == element)
  }

  @Test("filters elements by window and kind")
  func filtersElements() async {
    let registry = AccessibilityRegistry()
    await registry.registerElement(
      RegistryElement(
        identifier: "btn1",
        kind: .button,
        frame: RegistryRect(x: 0, y: 0, width: 1, height: 1),
        windowID: 100
      )
    )
    await registry.registerElement(
      RegistryElement(
        identifier: "btn2",
        kind: .button,
        frame: RegistryRect(x: 0, y: 0, width: 1, height: 1),
        windowID: 200
      )
    )
    await registry.registerElement(
      RegistryElement(
        identifier: "tf1",
        kind: .textField,
        frame: RegistryRect(x: 0, y: 0, width: 1, height: 1),
        windowID: 100
      )
    )
    let window100Buttons = await registry.allElements(windowID: 100, kind: .button)
    #expect(window100Buttons.map(\.identifier) == ["btn1"])

    let allWindow100 = await registry.allElements(windowID: 100)
    #expect(allWindow100.map(\.identifier) == ["btn1", "tf1"])

    let allButtons = await registry.allElements(kind: .button)
    #expect(allButtons.map(\.identifier) == ["btn1", "btn2"])
  }

  @Test("unregister removes the element")
  func unregister() async {
    let registry = AccessibilityRegistry()
    let element = RegistryElement(
      identifier: "dead",
      kind: .button,
      frame: RegistryRect(x: 0, y: 0, width: 0, height: 0)
    )
    await registry.registerElement(element)
    await registry.unregisterElement(identifier: "dead")
    let fetched = await registry.element(identifier: "dead")
    #expect(fetched == nil)
  }

  @Test("replacing window elements clears stale entries for that window only")
  func replaceWindowElementsClearsStaleEntries() async {
    let registry = AccessibilityRegistry()
    await registry.registerElement(
      RegistryElement(
        identifier: "main.keep",
        kind: .button,
        frame: RegistryRect(x: 0, y: 0, width: 1, height: 1),
        windowID: 100
      )
    )
    await registry.registerElement(
      RegistryElement(
        identifier: "prefs.keep",
        kind: .button,
        frame: RegistryRect(x: 0, y: 0, width: 1, height: 1),
        windowID: 200
      )
    )

    await registry.replaceWindowElements(
      windowID: 100,
      elements: [
        RegistryElement(
          identifier: "main.next",
          kind: .textField,
          frame: RegistryRect(x: 10, y: 20, width: 100, height: 24)
        )
      ]
    )

    let mainElements = await registry.allElements(windowID: 100)
    #expect(mainElements.map(\.identifier) == ["main.next"])
    #expect(mainElements.first?.windowID == 100)

    let prefsElements = await registry.allElements(windowID: 200)
    #expect(prefsElements.map(\.identifier) == ["prefs.keep"])
  }

  @MainActor
  @Test("stale window updates are ignored after tracking stops")
  func staleWindowUpdatesAreIgnoredAfterTrackingStops() async {
    let registry = AccessibilityRegistry()
    let controller = WindowRegistrySyncController(registry: registry)
    let entry = RegistryWindow(
      id: 101,
      title: "Tracked",
      frame: RegistryRect(x: 40, y: 50, width: 320, height: 240)
    )
    let generation = controller.beginTracking(windowID: entry.id)

    controller.sync(entry, generation: generation)
    controller.stopTracking()
    controller.sync(entry, generation: generation)

    await controller.waitForIdle()

    let windows = await registry.allWindows()
    #expect(windows.isEmpty)
  }

  @MainActor
  @Test("window element sync harvests and replaces tracked controls")
  func windowElementSyncHarvestsTrackedControls() async {
    let registry = AccessibilityRegistry()
    let controller = WindowElementRegistrySyncController(registry: registry)
    let window = NSWindow(
      contentRect: NSRect(x: 120, y: 180, width: 420, height: 320),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
    let button = NSButton(title: "Start", target: nil, action: nil)
    button.frame = NSRect(x: 40, y: 40, width: 120, height: 32)
    button.setAccessibilityIdentifier("session.controls.start")
    let field = NSTextField(string: "")
    field.placeholderString = "Search"
    field.frame = NSRect(x: 40, y: 96, width: 180, height: 24)
    field.setAccessibilityIdentifier("sidebar.search")
    root.addSubview(button)
    root.addSubview(field)
    window.contentView = root
    window.layoutIfNeeded()
    root.layoutSubtreeIfNeeded()

    let generation = controller.beginTracking(windowID: window.windowNumber)
    controller.sync(window: window, generation: generation)
    await controller.waitForIdle()

    let initialElements = await registry.allElements(windowID: window.windowNumber)
    #expect(initialElements.map(\.identifier) == ["session.controls.start", "sidebar.search"])
    #expect(initialElements.first(where: { $0.identifier == "session.controls.start" })?.kind == .button)
    #expect(initialElements.first(where: { $0.identifier == "sidebar.search" })?.kind == .textField)

    field.removeFromSuperview()
    controller.sync(window: window, generation: generation)
    await controller.waitForIdle()

    let refreshedElements = await registry.allElements(windowID: window.windowNumber)
    #expect(refreshedElements.map(\.identifier) == ["session.controls.start"])

    controller.stopTracking()
    await controller.waitForIdle()
    let clearedElements = await registry.allElements(windowID: window.windowNumber)
    #expect(clearedElements.isEmpty)
  }
}
