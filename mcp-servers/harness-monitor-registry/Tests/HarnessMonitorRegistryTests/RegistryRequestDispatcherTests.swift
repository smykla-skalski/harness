import Foundation
import Testing
@testable import HarnessMonitorRegistry

@Suite("RegistryRequestDispatcher")
struct RegistryRequestDispatcherTests {
  private func makeDispatcher() -> (AccessibilityRegistry, RegistryRequestDispatcher) {
    let registry = AccessibilityRegistry()
    let dispatcher = RegistryRequestDispatcher(registry: registry) {
      PingResult(
        protocolVersion: 1,
        appVersion: "1.2.3",
        bundleIdentifier: "io.harnessmonitor.app",
        capabilities: [.clientSnapshots, .clientSnapshotLeases, .replacementNotice]
      )
    }
    return (registry, dispatcher)
  }

  @Test("ping returns version info")
  func ping() async {
    let (_, dispatcher) = makeDispatcher()
    let response = await dispatcher.dispatch(RegistryRequest(id: 1, op: .ping)).response
    guard case .success(let id, let result) = response, id == 1, case .ping(let info) = result else {
      Issue.record("expected ping success, got \(response)")
      return
    }
    #expect(info.appVersion == "1.2.3")
    #expect(info.capabilities == [.clientSnapshots, .clientSnapshotLeases, .replacementNotice])
  }

  @Test("getElement returns not-found for unknown identifier")
  func notFound() async {
    let (_, dispatcher) = makeDispatcher()
    let response = await dispatcher.dispatch(
      RegistryRequest(id: 2, op: .getElement, identifier: "nope")
    ).response
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
    ).response
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
    ).response
    guard case .success(_, .listElements(let payload)) = response else {
      Issue.record("expected listElements success")
      return
    }
    #expect(payload.elements.map(\.identifier) == ["btn"])
  }

  @Test("syncClientSnapshot publishes remote client snapshots")
  func syncClientSnapshotPublishesRemoteClientSnapshots() async {
    let (registry, dispatcher) = makeDispatcher()
    let clientID = UUID()
    let response = await dispatcher.dispatch(
      RegistryRequest(
        id: 11,
        op: .syncClientSnapshot,
        clientSnapshot: RegistryClientSnapshot(
          clientID: clientID,
          appVersion: "1.2.3",
          bundleIdentifier: "io.test.client",
          snapshot: RegistrySnapshot(
            elements: [
              RegistryElement(
                identifier: "client.refresh",
                kind: .button,
                frame: RegistryRect(x: 10, y: 20, width: 24, height: 24),
                windowID: 7
              )
            ],
            windows: [
              RegistryWindow(
                id: 7,
                title: "Client Window",
                frame: RegistryRect(x: 0, y: 0, width: 100, height: 80)
              )
            ]
          )
        )
      )
    ).response

    guard case .success(_, .ack(let ack)) = response else {
      Issue.record("expected syncClientSnapshot ack")
      return
    }
    #expect(ack.applied == true)
    #expect(await registry.element(identifier: "client.refresh")?.windowID == 7)
  }

  @Test("replacementNotice delegates to the handler")
  func replacementNoticeDelegatesToTheHandler() async {
    let registry = AccessibilityRegistry()
    let probe = ReplacementDeliveryProbe()
    let notice = RegistryReplacementNotice(
      socketPath: "/tmp/mcp.sock",
      protocolVersion: 1,
      appVersion: "1.2.4",
      bundleIdentifier: "io.harnessmonitor.app",
      message: "replacement incoming"
    )
    let dispatcher = RegistryRequestDispatcher(
      registry: registry,
      pingInfo: {
        PingResult(protocolVersion: 1, appVersion: "1.2.3", bundleIdentifier: "io.harnessmonitor.app")
      },
      replacementHandler: { receivedNotice in
        RegistryRequestDispatcher.ReplacementDisposition(
          ack: RegistryAckResult(applied: receivedNotice == notice),
          onDelivered: {
            await probe.recordDelivery()
          },
          closeConnectionAfterDelivery: receivedNotice == notice
        )
      }
    )

    let dispatchResult = await dispatcher.dispatch(
      RegistryRequest(id: 12, op: .replacementNotice, replacementNotice: notice)
    )
    let response = dispatchResult.response

    guard case .success(_, .ack(let ack)) = response else {
      Issue.record("expected replacementNotice ack")
      return
    }
    #expect(ack == RegistryAckResult(applied: true))
    #expect(dispatchResult.closeConnectionAfterDelivery == true)
    #expect(await probe.deliveryCount() == 0)
    if let onDelivered = dispatchResult.onDelivered {
      await onDelivered()
    } else {
      Issue.record("expected replacementNotice delivery callback")
    }
    #expect(await probe.deliveryCount() == 1)
  }
}

private actor ReplacementDeliveryProbe {
  private var deliveries = 0

  func recordDelivery() {
    deliveries += 1
  }

  func deliveryCount() -> Int {
    deliveries
  }
}
