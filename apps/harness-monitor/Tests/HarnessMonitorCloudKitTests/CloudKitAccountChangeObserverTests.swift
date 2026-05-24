import Foundation
@testable import HarnessMonitorCloudKit
import XCTest

@MainActor
final class CloudKitAccountChangeObserverTests: XCTestCase {
  func testStartSubscribesToNotificationAndFiresHandler() async {
    let center = NotificationCenter()
    let name = Notification.Name("test.account-change.fires")
    let counter = AsyncCounter()
    let handler = CloudKitAccountChangeHandler(
      invalidate: { await counter.increment() },
      register: { }
    )
    let observer = CloudKitAccountChangeObserver(
      handler: handler,
      notificationCenter: center,
      notificationName: name
    )

    observer.start()
    center.post(name: name, object: nil)
    let value = await waitFor(expected: 1, getter: { await counter.value })

    XCTAssertEqual(value, 1)
  }

  func testStartIsIdempotent() async {
    let center = NotificationCenter()
    let name = Notification.Name("test.account-change.idempotent")
    let counter = AsyncCounter()
    let handler = CloudKitAccountChangeHandler(
      invalidate: { await counter.increment() },
      register: { }
    )
    let observer = CloudKitAccountChangeObserver(
      handler: handler,
      notificationCenter: center,
      notificationName: name
    )

    observer.start()
    observer.start()
    center.post(name: name, object: nil)
    let value = await waitFor(expected: 1, getter: { await counter.value })

    XCTAssertEqual(value, 1, "Duplicate start() must not double-subscribe")
  }

  func testStopCancelsSubscription() async {
    let center = NotificationCenter()
    let name = Notification.Name("test.account-change.stop")
    let counter = AsyncCounter()
    let handler = CloudKitAccountChangeHandler(
      invalidate: { await counter.increment() },
      register: { }
    )
    let observer = CloudKitAccountChangeObserver(
      handler: handler,
      notificationCenter: center,
      notificationName: name
    )

    observer.start()
    observer.stop()
    center.post(name: name, object: nil)
    try? await Task.sleep(nanoseconds: 200_000_000)

    let value = await counter.value
    XCTAssertEqual(value, 0)
  }

  func testStartAfterStopRearmsSubscription() async {
    let center = NotificationCenter()
    let name = Notification.Name("test.account-change.rearm")
    let counter = AsyncCounter()
    let handler = CloudKitAccountChangeHandler(
      invalidate: { await counter.increment() },
      register: { }
    )
    let observer = CloudKitAccountChangeObserver(
      handler: handler,
      notificationCenter: center,
      notificationName: name
    )

    observer.start()
    observer.stop()
    observer.start()
    center.post(name: name, object: nil)
    let value = await waitFor(expected: 1, getter: { await counter.value })

    XCTAssertEqual(value, 1)
  }

  private func waitFor(
    expected: Int,
    getter: @Sendable () async -> Int,
    timeoutMillis: Int = 1_000
  ) async -> Int {
    let stepNanos: UInt64 = 20_000_000
    let maxSteps = max(1, timeoutMillis / 20)
    var current = await getter()
    var steps = 0
    while current != expected && steps < maxSteps {
      try? await Task.sleep(nanoseconds: stepNanos)
      current = await getter()
      steps += 1
    }
    return current
  }
}

private actor AsyncCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}
