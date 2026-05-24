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

  @Test("snapshot prefers background delivery when windows cannot receive focus")
  func snapshotPrefersBackgroundDeliveryForMissingFocusableWindows() {
    #expect(
      KeyWindowSnapshot(
        keyWindowIdentifier: "main",
        isAppActive: true,
        appIsHidden: false,
        hasVisibleNonMiniaturizedWindows: false
      ).prefersUserNotificationDelivery
    )

    #expect(
      KeyWindowSnapshot(
        keyWindowIdentifier: nil,
        isAppActive: true,
        appIsHidden: false,
        hasVisibleNonMiniaturizedWindows: true
      ).prefersUserNotificationDelivery
    )
  }

  @Test("observer refreshes from window lifecycle notifications")
  func observerRefreshesFromNotifications() async {
    let notificationCenter = NotificationCenter()
    let application = FakeKeyWindowApplication(
      keyWindowIdentifier: "main",
      keyWindowParentIdentifier: nil,
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
    application.keyWindowParentIdentifier = nil
    application.isActive = false
    application.windowStates = [
      KeyWindowState(identifier: "main", isVisible: true, isMiniaturized: true)
    ]

    notificationCenter.post(name: NSWindow.didMiniaturizeNotification, object: nil)
    await Task.yield()
    await Task.yield()

    #expect(observer.snapshot.keyWindowIdentifier == nil)
    #expect(observer.snapshot.prefersUserNotificationDelivery)
  }

  @Test("observer keeps the parent window active while a sheet is key")
  func observerFallsBackToSheetParentIdentifier() async {
    let notificationCenter = NotificationCenter()
    let application = FakeKeyWindowApplication(
      keyWindowIdentifier: "main-sheet",
      keyWindowParentIdentifier: "main",
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

    #expect(observer.snapshot.keyWindowIdentifier == "main")
    #expect(observer.isKey(windowID: "main"))

    application.keyWindowIdentifier = "main"
    application.keyWindowParentIdentifier = nil
    notificationCenter.post(name: NSWindow.didBecomeKeyNotification, object: nil)
    await Task.yield()
    await Task.yield()

    #expect(observer.snapshot.keyWindowIdentifier == "main")
    #expect(observer.isKey(windowID: "main"))
    #expect(!observer.snapshot.prefersUserNotificationDelivery)
  }
}

@MainActor
private final class FakeKeyWindowApplication: KeyWindowObservableApplication {
  var keyWindowIdentifier: String?
  var keyWindowParentIdentifier: String?
  var isActive: Bool
  var isHidden: Bool
  var windowStates: [KeyWindowState]

  init(
    keyWindowIdentifier: String?,
    keyWindowParentIdentifier: String?,
    isActive: Bool,
    isHidden: Bool,
    windowStates: [KeyWindowState]
  ) {
    self.keyWindowIdentifier = keyWindowIdentifier
    self.keyWindowParentIdentifier = keyWindowParentIdentifier
    self.isActive = isActive
    self.isHidden = isHidden
    self.windowStates = windowStates
  }
}
