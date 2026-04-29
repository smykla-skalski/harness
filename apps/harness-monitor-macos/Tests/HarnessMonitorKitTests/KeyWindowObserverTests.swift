import AppKit
import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
struct KeyWindowObserverTests {
  @Test("snapshot prefers background delivery when the app is hidden or inactive")
  func snapshotPrefersBackgroundDeliveryForHiddenStates() {
    #expect(
      KeyWindowSnapshot(
        keyWindowIdentifier: "main",
        isAppActive: true,
        appIsHidden: true,
        hasVisibleNonMiniaturizedWindows: true
      ).prefersUserNotificationDelivery
    )

    #expect(
      KeyWindowSnapshot(
        keyWindowIdentifier: "main",
        isAppActive: false,
        appIsHidden: false,
        hasVisibleNonMiniaturizedWindows: true
      ).prefersUserNotificationDelivery
    )
  }

  @Test("observer refreshes from window lifecycle notifications")
  func observerRefreshesFromNotifications() {
    let notificationCenter = NotificationCenter()
    let application = FakeKeyWindowApplication(
      keyWindowIdentifier: "main",
      isActive: true,
      isHidden: false,
      windowStates: [
        KeyWindowState(identifier: "main", isVisible: true, isMiniaturized: false)
      ]
    )
    let observer = KeyWindowObserver(
      application: application,
      notificationCenter: notificationCenter
    )

    #expect(observer.isKey(windowID: "main"))
    #expect(!observer.snapshot.prefersUserNotificationDelivery)

    application.keyWindowIdentifier = nil
    application.isActive = false
    application.windowStates = [
      KeyWindowState(identifier: "main", isVisible: true, isMiniaturized: true)
    ]

    notificationCenter.post(name: NSWindow.didMiniaturizeNotification, object: nil)

    #expect(observer.snapshot.keyWindowIdentifier == nil)
    #expect(observer.snapshot.prefersUserNotificationDelivery)
  }
}

@MainActor
private final class FakeKeyWindowApplication: KeyWindowObservableApplication {
  var keyWindowIdentifier: String?
  var isActive: Bool
  var isHidden: Bool
  var windowStates: [KeyWindowState]

  init(
    keyWindowIdentifier: String?,
    isActive: Bool,
    isHidden: Bool,
    windowStates: [KeyWindowState]
  ) {
    self.keyWindowIdentifier = keyWindowIdentifier
    self.isActive = isActive
    self.isHidden = isHidden
    self.windowStates = windowStates
  }
}
