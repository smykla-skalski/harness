import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor launch mode")
struct HarnessMonitorLaunchModeTests {
  @Test("Missing environment defaults to live")
  func defaultsToLiveWhenEnvironmentValueIsMissing() {
    #expect(HarnessMonitorLaunchMode(environment: [:]) == .live)
  }

  @Test("Preview environment value maps to preview mode")
  func parsesPreviewMode() {
    #expect(
      HarnessMonitorLaunchMode(environment: [HarnessMonitorLaunchMode.environmentKey: "preview"]) == .preview
    )
  }

  @Test("Empty environment value maps to empty mode")
  func parsesEmptyMode() {
    #expect(
      HarnessMonitorLaunchMode(environment: [HarnessMonitorLaunchMode.environmentKey: "empty"]) == .empty
    )
  }

  @Test("Unknown environment values fall back to live mode")
  func fallsBackToLiveForUnknownMode() {
    #expect(
      HarnessMonitorLaunchMode(environment: [HarnessMonitorLaunchMode.environmentKey: "mystery"]) == .live
    )
  }
}
