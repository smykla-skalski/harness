import AppKit
import XCTest

@testable import HarnessMonitor

final class HarnessMonitorAppLifecyclePolicyTests: XCTestCase {
  @MainActor
  func testLiveLaunchStartsAsAccessoryUntilAnApplicationWindowOpens() {
    XCTAssertEqual(
      HarnessMonitorAppDelegate.applicationPresenceMode(
        hidesDockIconForPerfRuns: false,
        isTestHarnessRun: false
      ),
      .dynamic
    )
  }

  @MainActor
  func testTestAndPerformanceLaunchesKeepTheirExistingActivationPolicies() {
    XCTAssertEqual(
      HarnessMonitorAppDelegate.applicationPresenceMode(
        hidesDockIconForPerfRuns: false,
        isTestHarnessRun: true
      ),
      .alwaysRegular
    )
    XCTAssertEqual(
      HarnessMonitorAppDelegate.applicationPresenceMode(
        hidesDockIconForPerfRuns: true,
        isTestHarnessRun: false
      ),
      .alwaysAccessory
    )
  }

  @MainActor
  func testDynamicPresenceShowsDockOnlyWhileApplicationWindowsAreOpen() {
    var appliedPolicies: [NSApplication.ActivationPolicy] = []
    let controller = HarnessMonitorApplicationPresenceController(
      setActivationPolicy: { policy in
        appliedPolicies.append(policy)
        return true
      }
    )
    let dashboard = NSObject()
    let settings = NSObject()

    controller.configure(mode: .dynamic)
    controller.applicationWindowDidOpen(ObjectIdentifier(dashboard))
    controller.applicationWindowDidOpen(ObjectIdentifier(settings))
    controller.applicationWindowWillClose(ObjectIdentifier(dashboard))
    controller.applicationWindowWillClose(ObjectIdentifier(settings))

    XCTAssertEqual(appliedPolicies, [.accessory, .regular, .accessory])
  }

  @MainActor
  func testPerformanceModeNeverPromotesTheDock() {
    var appliedPolicies: [NSApplication.ActivationPolicy] = []
    let controller = HarnessMonitorApplicationPresenceController(
      setActivationPolicy: { policy in
        appliedPolicies.append(policy)
        return true
      }
    )
    let dashboard = NSObject()

    controller.configure(mode: .alwaysAccessory)
    controller.applicationWindowDidOpen(ObjectIdentifier(dashboard))

    XCTAssertEqual(appliedPolicies, [.accessory])
  }

  func testNormalLaunchKeepsProcessAliveAfterLastWindowCloses() {
    XCTAssertFalse(
      HarnessMonitorAppDelegate.shouldTerminateAfterLastWindowClosed(isTestHarnessRun: false)
    )
  }

  func testTestHarnessLaunchTerminatesAfterLastWindowCloses() {
    XCTAssertTrue(
      HarnessMonitorAppDelegate.shouldTerminateAfterLastWindowClosed(isTestHarnessRun: true)
    )
  }

  func testDockReopenRequestsMainWindowOnlyWhenNoWindowsAreVisible() {
    XCTAssertTrue(
      HarnessMonitorAppDelegate.shouldRequestMainWindowOnReopen(hasVisibleWindows: false)
    )
    XCTAssertFalse(
      HarnessMonitorAppDelegate.shouldRequestMainWindowOnReopen(hasVisibleWindows: true)
    )
  }

  @MainActor
  func testMainWindowLauncherQueuesRequestsUntilSwiftUIBindsOpenWindowAction() {
    let launcher = HarnessMonitorMainWindowLauncher.shared
    launcher.resetForTesting()
    addTeardownBlock { @MainActor in launcher.resetForTesting() }

    launcher.requestOpenMainWindow()
    XCTAssertTrue(launcher.hasPendingOpenRequestForTesting)

    var openCount = 0
    launcher.installOpenMainWindow {
      openCount += 1
    }

    XCTAssertEqual(openCount, 1)
    XCTAssertFalse(launcher.hasPendingOpenRequestForTesting)

    launcher.requestOpenMainWindow()
    XCTAssertEqual(openCount, 2)
  }

  @MainActor
  func testDockReopenQueuesMainWindowRequestWhenOpenWindowActionIsNotBoundYet() {
    let launcher = HarnessMonitorMainWindowLauncher.shared
    launcher.resetForTesting()
    addTeardownBlock { @MainActor in launcher.resetForTesting() }
    let delegate = HarnessMonitorAppDelegate()

    let usesDefaultReopen = delegate.applicationShouldHandleReopen(
      NSApplication.shared,
      hasVisibleWindows: false
    )

    XCTAssertFalse(usesDefaultReopen)
    XCTAssertTrue(launcher.hasPendingOpenRequestForTesting)
  }
}
