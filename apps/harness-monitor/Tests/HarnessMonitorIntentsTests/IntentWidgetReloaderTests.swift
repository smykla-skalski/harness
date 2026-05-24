import Foundation
import XCTest

@testable import HarnessMonitorIntents

final class IntentWidgetReloaderTests: XCTestCase {
  override func tearDown() async throws {
    await IntentWidgetReloader.shared.setOverrideForTesting(nil)
    try await super.tearDown()
  }

  func testReloadInvokesOverrideWithKind() async {
    let recorder = ReloadRecorder()
    await IntentWidgetReloader.shared.setOverrideForTesting { kind in
      recorder.append(kind)
    }

    await IntentWidgetReloader.shared.reload(kind: "test-kind")

    XCTAssertEqual(recorder.observed(), ["test-kind"])
  }

  func testReloadNeedsMeCountTargetsMacOSKind() async {
    let recorder = ReloadRecorder()
    await IntentWidgetReloader.shared.setOverrideForTesting { kind in
      recorder.append(kind)
    }

    await IntentWidgetReloader.shared.reloadNeedsMeCount()

    XCTAssertEqual(recorder.observed(), [HarnessMonitorWidgetKinds.needsMeCount])
    XCTAssertEqual(HarnessMonitorWidgetKinds.needsMeCount, "needs-me-count")
  }

  func testRepeatedReloadsAccumulate() async {
    let recorder = ReloadRecorder()
    await IntentWidgetReloader.shared.setOverrideForTesting { kind in
      recorder.append(kind)
    }

    await IntentWidgetReloader.shared.reloadNeedsMeCount()
    await IntentWidgetReloader.shared.reloadNeedsMeCount()
    await IntentWidgetReloader.shared.reloadNeedsMeCount()

    XCTAssertEqual(recorder.observed().count, 3)
  }

  func testIntentReloaderConstantStaysStable() {
    XCTAssertEqual(HarnessMonitorWidgetKinds.needsMeCount, "needs-me-count")
    XCTAssertEqual(HarnessMonitorWidgetKinds.needsMeCountWatch, "needs-me-count-watch")
  }
}

private final class ReloadRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var kinds: [String] = []

  func append(_ kind: String) {
    lock.lock()
    defer { lock.unlock() }
    kinds.append(kind)
  }

  func observed() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return kinds
  }
}
