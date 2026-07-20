import XCTest

@testable import HarnessMonitorKit

@MainActor
final class HarnessMonitorStoreMobileRelayClientTests: XCTestCase {
  func testMobileRelayClientUsesActiveStoreClientWithoutWarmUp() async throws {
    let daemon = RecordingDaemonController()
    let store = HarnessMonitorStore(daemonController: daemon)
    store.client = PreviewHarnessClient()

    _ = try await store.clientForMobileRelay()
    let warmUpCallCount = await daemon.recordedWarmUpCallCount()

    XCTAssertEqual(warmUpCallCount, 0)
  }

  func testMobileRelayClientBootstrapsStoreInsteadOfOpeningSecondConnection() async throws {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    _ = try await store.clientForMobileRelay()
    let warmUpCallCount = await daemon.recordedWarmUpCallCount()

    XCTAssertEqual(warmUpCallCount, 1)
    XCTAssertNotNil(store.client)
    XCTAssertNil(store.mobileRelayBackgroundClient)
  }

  func testMobileRelayClientWarmsDaemonWhenAppConnectionIsSuspended() async throws {
    let daemon = RecordingDaemonController(client: PreviewHarnessClient())
    let store = HarnessMonitorStore(daemonController: daemon)
    store.isAppLifecycleSuspended = true

    let client = try await store.clientForMobileRelay()
    let warmUpCallCount = await daemon.recordedWarmUpCallCount()

    XCTAssertNotNil(client)
    XCTAssertNil(store.apiClient)
    XCTAssertEqual(warmUpCallCount, 1)
  }
}
