import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Legacy managed launch-agent containment", .serialized)
struct LegacyManagedLaunchAgentContainmentTests {
  @Test("Containment rechecks legacy services after foreground startup")
  func containmentRechecksLegacyServices() async throws {
    let daemon = RecordingDaemonController(
      legacyCleanupError: DaemonControlError.commandFailed("legacy service returned")
    )
    let containment = LegacyManagedLaunchAgentContainment(interval: .milliseconds(10))

    containment.start(controller: daemon)
    for _ in 0..<20 where await daemon.recordedLegacyCleanupCallCount() < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    containment.cancel()

    #expect(await daemon.recordedLegacyCleanupCallCount() >= 2)
  }
}
