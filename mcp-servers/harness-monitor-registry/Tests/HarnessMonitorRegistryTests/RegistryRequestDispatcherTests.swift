import Testing
@testable import HarnessMonitorRegistry

@Suite("RegistryRequestDispatcher")
struct RegistryRequestDispatcherTests {
  private func makeDispatcher() -> (AccessibilityRegistry, RegistryRequestDispatcher) {
    let registry = AccessibilityRegistry()
    let dispatcher = RegistryRequestDispatcher(registry: registry) {
      PingResult(protocolVersion: 1, appVersion: "1.2.3", bundleIdentifier: "io.harnessmonitor.app")
    }
    return (registry, dispatcher)
  }

  @Test("ping returns version info")
  func ping() async {
    let (_, dispatcher) = makeDispatcher()
    let response = await dispatcher.dispatch(RegistryRequest(id: 1, op: .ping))
    guard case .success(let id, let result) = response, id == 1, case .ping(let info) = result else {
      Issue.record("expected ping success, got \(response)")
      return
    }
    #expect(info.appVersion == "1.2.3")
  }

  @Test("getElement returns not-found for unknown identifier")
  func notFound() async {
    let (_, dispatcher) = makeDispatcher()
    let response = await dispatcher.dispatch(
      RegistryRequest(id: 2, op: .getElement, identifier: "nope")
    )
    guard case .failure(let id, let error) = response else {
      Issue.record("expected failure")
      return
    }
    #expect(id == 2)
    #expect(error.code == "not-found")
  }

  @Test("getElement rejects empty identifier")
  func emptyIdentifier() async {
    let (_, dispatcher) = makeDispatcher()
    let response = await dispatcher.dispatch(
      RegistryRequest(id: 3, op: .getElement, identifier: "")
    )
    guard case .failure(let id, let error) = response else {
      Issue.record("expected failure")
      return
    }
    #expect(id == 3)
    #expect(error.code == "invalid-argument")
  }

  @Test("listElements applies window and kind filters")
  func listElementsFilters() async {
    let (registry, dispatcher) = makeDispatcher()
    await registry.registerElement(
      RegistryElement(
        identifier: "btn",
        kind: .button,
        frame: RegistryRect(x: 0, y: 0, width: 0, height: 0),
        windowID: 42
      )
    )
    await registry.registerElement(
      RegistryElement(
        identifier: "txt",
        kind: .textField,
        frame: RegistryRect(x: 0, y: 0, width: 0, height: 0),
        windowID: 42
      )
    )
    let response = await dispatcher.dispatch(
      RegistryRequest(id: 9, op: .listElements, windowID: 42, kind: .button)
    )
    guard case .success(_, .listElements(let payload)) = response else {
      Issue.record("expected listElements success")
      return
    }
    #expect(payload.elements.map(\.identifier) == ["btn"])
  }
}
