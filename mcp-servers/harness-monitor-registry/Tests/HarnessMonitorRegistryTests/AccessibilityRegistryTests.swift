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
}
