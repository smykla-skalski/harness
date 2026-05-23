import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews reload key stability")
struct DashboardReviewsReloadStabilityTests {
  @Test("isReviewsReloadConnected returns true only for .online")
  func isReviewsReloadConnectedReturnsTrueOnlyForOnline() {
    #expect(isReviewsReloadConnected(.online) == true)
    #expect(isReviewsReloadConnected(.idle) == false)
    #expect(isReviewsReloadConnected(.connecting) == false)
    #expect(isReviewsReloadConnected(.offline("Daemon stopped")) == false)
  }

  @Test("isConnected does not flip on the intermediate .connecting state")
  func isConnectedDoesNotFlipOnIntermediateConnectingState() {
    // The point of the new flag: walking from `offline` through `connecting`
    // to `online` must not toggle the boolean in the middle. Otherwise the
    // .task(id:) observer fires a reload at the `connecting` edge and again
    // at the `online` edge, doubling the work each time the websocket flaps.
    let walk: [HarnessMonitorStore.ConnectionState] = [
      .offline("Daemon stopped"),
      .connecting,
      .online,
    ]
    let flags = walk.map(isReviewsReloadConnected)
    #expect(flags == [false, false, true])
  }

  @Test("connection flap offline -> connecting -> online produces one reload key change")
  func connectionFlapOfflineConnectingOnlineProducesOneReloadKeyChange() {
    // Simulate the route view rebuilding its reload key as the daemon
    // websocket flaps. Each state in the walk produces a key; we count the
    // distinct adjacent transitions. Under the old `connectionState:` field
    // this was 2 (offline -> connecting and connecting -> online). Under the
    // new `isConnected:` Bool it must be 1 (the offline -> online edge).
    let walk: [HarnessMonitorStore.ConnectionState] = [
      .offline("Daemon stopped"),
      .connecting,
      .online,
    ]
    let keys = walk.map {
      DashboardReviewsReloadTaskKey(
        preferencesSignature: "preferences=stable",
        isConnected: isReviewsReloadConnected($0)
      )
    }
    var changes = 0
    for i in 1..<keys.count where keys[i] != keys[i - 1] {
      changes += 1
    }
    #expect(changes == 1)
  }

  @Test("connection drop online -> offline triggers exactly one key change")
  func connectionDropOnlineOfflineTriggersExactlyOneKeyChange() {
    let walk: [HarnessMonitorStore.ConnectionState] = [
      .online,
      .connecting,
      .offline("Daemon stopped"),
    ]
    let keys = walk.map {
      DashboardReviewsReloadTaskKey(
        preferencesSignature: "preferences=stable",
        isConnected: isReviewsReloadConnected($0)
      )
    }
    var changes = 0
    for i in 1..<keys.count where keys[i] != keys[i - 1] {
      changes += 1
    }
    #expect(changes == 1)
  }

  @Test("rapid flap idle -> connecting -> idle does not change the reload key")
  func rapidFlapIdleConnectingIdleDoesNotChangeReloadKey() {
    // A daemon that is never quite reachable should not cause repeated
    // reload churn just because the store cycles through transient states.
    let walk: [HarnessMonitorStore.ConnectionState] = [.idle, .connecting, .idle]
    let keys = walk.map {
      DashboardReviewsReloadTaskKey(
        preferencesSignature: "preferences=stable",
        isConnected: isReviewsReloadConnected($0)
      )
    }
    #expect(Set(keys).count == 1)
  }

  @Test("preferences signature still drives a reload while disconnected")
  func preferencesSignatureStillDrivesAReloadWhileDisconnected() {
    let oldKey = DashboardReviewsReloadTaskKey(
      preferencesSignature: "authors=a",
      isConnected: false
    )
    let newKey = DashboardReviewsReloadTaskKey(
      preferencesSignature: "authors=b",
      isConnected: false
    )
    #expect(oldKey != newKey)
  }
}
