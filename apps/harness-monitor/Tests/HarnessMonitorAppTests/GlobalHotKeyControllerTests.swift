import AppKit
import Carbon
import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorKit

final class GlobalHotKeyControllerTests: XCTestCase {
  @MainActor
  func testAppActivationRetriesFailedRegistration() {
    var registrationAttempts = 0
    let controller = GlobalHotKeyController(
      installEventHandler: { _, _, _ in noErr },
      registerEventHotKey: { _, _, _ in
        registrationAttempts += 1
        return registrationAttempts == 1 ? OSStatus(-1) : noErr
      }
    )
    controller.configure(
      enabled: true,
      descriptor: .defaultValue,
      onInvoke: {}
    )

    XCTAssertEqual(registrationAttempts, 1)

    let delegate = HarnessMonitorAppDelegate()
    delegate.bind(globalHotKeyController: controller)
    delegate.applicationDidBecomeActive(
      Notification(name: NSApplication.didBecomeActiveNotification)
    )
    delegate.applicationDidBecomeActive(
      Notification(name: NSApplication.didBecomeActiveNotification)
    )

    XCTAssertEqual(registrationAttempts, 2)
  }

  @MainActor
  func testAppActivationRetriesFailedEventHandlerInstallation() {
    var installationAttempts = 0
    var registrationAttempts = 0
    let controller = GlobalHotKeyController(
      installEventHandler: { _, _, _ in
        installationAttempts += 1
        return installationAttempts == 1 ? OSStatus(-1) : noErr
      },
      registerEventHotKey: { _, _, _ in
        registrationAttempts += 1
        return noErr
      }
    )
    controller.configure(
      enabled: true,
      descriptor: .defaultValue,
      onInvoke: {}
    )

    XCTAssertEqual(installationAttempts, 1)
    XCTAssertEqual(registrationAttempts, 0)

    let delegate = HarnessMonitorAppDelegate()
    delegate.bind(globalHotKeyController: controller)
    delegate.applicationDidBecomeActive(
      Notification(name: NSApplication.didBecomeActiveNotification)
    )
    delegate.applicationDidBecomeActive(
      Notification(name: NSApplication.didBecomeActiveNotification)
    )

    XCTAssertEqual(installationAttempts, 2)
    XCTAssertEqual(registrationAttempts, 1)
  }

  @MainActor
  func testDisabledShortcutDoesNotRetryFailedRegistration() {
    var registrationAttempts = 0
    let controller = GlobalHotKeyController(
      installEventHandler: { _, _, _ in noErr },
      registerEventHotKey: { _, _, _ in
        registrationAttempts += 1
        return OSStatus(-1)
      }
    )
    controller.configure(
      enabled: true,
      descriptor: .defaultValue,
      onInvoke: {}
    )
    controller.configure(
      enabled: false,
      descriptor: .defaultValue,
      onInvoke: {}
    )

    let delegate = HarnessMonitorAppDelegate()
    delegate.bind(globalHotKeyController: controller)
    delegate.applicationDidBecomeActive(
      Notification(name: NSApplication.didBecomeActiveNotification)
    )

    XCTAssertEqual(registrationAttempts, 1)
  }
}
