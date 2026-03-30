import Testing

@testable import HarnessKit

@Suite("Harness launch mode")
struct HarnessLaunchModeTests {
  @Test("Missing environment defaults to live")
  func defaultsToLiveWhenEnvironmentValueIsMissing() {
    #expect(HarnessLaunchMode(environment: [:]) == .live)
  }

  @Test("Preview environment value maps to preview mode")
  func parsesPreviewMode() {
    #expect(
      HarnessLaunchMode(environment: [HarnessLaunchMode.environmentKey: "preview"]) == .preview
    )
  }

  @Test("Empty environment value maps to empty mode")
  func parsesEmptyMode() {
    #expect(
      HarnessLaunchMode(environment: [HarnessLaunchMode.environmentKey: "empty"]) == .empty
    )
  }

  @Test("Unknown environment values fall back to live mode")
  func fallsBackToLiveForUnknownMode() {
    #expect(
      HarnessLaunchMode(environment: [HarnessLaunchMode.environmentKey: "mystery"]) == .live
    )
  }
}
