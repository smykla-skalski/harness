import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor launch mode")
struct HarnessMonitorLaunchModeTests {
  @Test("Missing environment defaults to live")
  func defaultsToLiveWhenEnvironmentValueIsMissing() {
    #expect(HarnessMonitorLaunchMode(environment: [:]) == .live)
  }

  @Test("Xcode preview sessions default to preview mode when launch mode is unset")
  func defaultsToPreviewForXcodeCanvas() {
    #expect(
      HarnessMonitorLaunchMode(environment: [
        HarnessMonitorLaunchMode.xcodePreviewEnvironmentKey: "1"
      ])
        == .preview
    )
  }

  @Test("Xcode preview JIT executor sessions default to preview mode")
  func defaultsToPreviewForXcodePlaygroundExecutor() {
    #expect(
      HarnessMonitorLaunchMode(environment: [
        HarnessMonitorLaunchMode.xcodePlaygroundsEnvironmentKey: "1"
      ])
        == .preview
    )
  }

  @Test("Preview environment value maps to preview mode")
  func parsesPreviewMode() {
    #expect(
      HarnessMonitorLaunchMode(environment: [HarnessMonitorLaunchMode.environmentKey: "preview"])
        == .preview
    )
  }

  @Test("Empty environment value maps to empty mode")
  func parsesEmptyMode() {
    #expect(
      HarnessMonitorLaunchMode(environment: [HarnessMonitorLaunchMode.environmentKey: "empty"])
        == .empty
    )
  }

  @Test("Unknown environment values fall back to live mode")
  func fallsBackToLiveForUnknownMode() {
    #expect(
      HarnessMonitorLaunchMode(environment: [HarnessMonitorLaunchMode.environmentKey: "mystery"])
        == .live
    )
  }

  @Test("Explicit launch mode overrides the Xcode preview fallback")
  func explicitLaunchModeWinsOverXcodePreviewEnvironment() {
    #expect(
      HarnessMonitorLaunchMode(environment: [
        HarnessMonitorLaunchMode.environmentKey: "empty",
        HarnessMonitorLaunchMode.xcodePreviewEnvironmentKey: "1",
      ]) == .empty
    )
  }

  @Test("Visible windows keep the live connection active on app resign active")
  func visibleWindowsKeepLiveConnectionActive() {
    #expect(
      HarnessMonitorAppVisibilityPolicy.shouldSuspendLiveConnection(
        appIsHidden: false,
        hasVisibleNonMiniaturizedWindows: true
      ) == false
    )
  }

  @Test("Hidden app suspends the live connection on app resign active")
  func hiddenAppSuspendsLiveConnection() {
    #expect(
      HarnessMonitorAppVisibilityPolicy.shouldSuspendLiveConnection(
        appIsHidden: true,
        hasVisibleNonMiniaturizedWindows: true
      )
    )
  }

  @Test("No visible windows suspend the live connection on app resign active")
  func noVisibleWindowsSuspendLiveConnection() {
    #expect(
      HarnessMonitorAppVisibilityPolicy.shouldSuspendLiveConnection(
        appIsHidden: false,
        hasVisibleNonMiniaturizedWindows: false
      )
    )
  }
}
