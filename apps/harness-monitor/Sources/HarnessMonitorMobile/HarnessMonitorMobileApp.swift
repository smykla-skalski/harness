import HarnessMonitorCloudKit
import HarnessMonitorCloudMirror
import HarnessMonitorCrypto
import SwiftUI
import UIKit
import WidgetKit

@main
struct HarnessMonitorMobileApp: App {
  @UIApplicationDelegateAdaptor(MobileAppDelegate.self)
  private var delegate
  @Environment(\.scenePhase)
  private var scenePhase
  @State private var store: MobileMonitorStore
  @State private var pendingPairingURL: URL?
  @State private var selectedTab: MobileRootTab = .today

  init() {
    let identityStore = KeychainMobileDeviceIdentityStore()
    let credentialStore = KeychainMobilePairedStationCredentialStore()
    let watchPairingSyncer = MobileWatchPairingSessionBridge(
      identityStore: identityStore,
      credentialStore: credentialStore
    )
    _store = State(
      initialValue: MobileMonitorStore(
        identityStore: identityStore,
        credentialStore: credentialStore,
        pairer: LiveMobileMonitorCredentialPairer(
          identityStore: identityStore,
          credentialStore: credentialStore
        ),
        watchPairingSyncer: watchPairingSyncer
      )
    )
  }

  var body: some Scene {
    WindowGroup {
      MobileRootView(selectedTab: $selectedTab)
        .environment(store)
        .onOpenURL { url in
          guard url.scheme == MobilePairingInvitationCodec.urlScheme,
            url.host == MobilePairingInvitationCodec.urlHost
          else {
            if let tab = MobileRootTab(url: url) {
              selectedTab = tab
            }
            return
          }
          pendingPairingURL = url
          pairPendingInvitationIfActive()
        }
        .onChange(of: scenePhase) { _, newPhase in
          guard newPhase == .active else {
            return
          }
          guard !pairPendingInvitationIfActive() else {
            return
          }
          refreshLiveMirrorIfActive()
        }
        .onReceive(
          NotificationCenter.default.publisher(for: .mobileMirrorRemoteRefreshRequested)
        ) { _ in
          refreshLiveMirrorIfActive()
        }
    }
  }

  @discardableResult
  private func pairPendingInvitationIfActive() -> Bool {
    guard scenePhase == .active, let url = pendingPairingURL else {
      return false
    }
    pendingPairingURL = nil
    Task {
      await store.handleOpenURL(url, deviceName: UIDevice.current.name)
    }
    return true
  }

  private func refreshLiveMirrorIfActive() {
    guard scenePhase == .active else {
      return
    }
    Task {
      await store.loadStoredPairings()
      await store.refresh()
    }
  }
}

extension Notification.Name {
  static let mobileMirrorRemoteRefreshRequested = Notification.Name(
    "io.harnessmonitor.mobile.mirrorRemoteRefreshRequested"
  )
}

@MainActor
final class MobileAppDelegate: NSObject, UIApplicationDelegate {
  private let accountObserver: CloudKitAccountChangeObserver

  override init() {
    accountObserver = CloudKitAccountChangeObserver(
      handler: CloudKitAccountChangeHandler(
        invalidate: {
          await NeedsMeCloudKitSubscriptionService.shared.invalidateForAccountChange()
          await MobileCloudMirrorSubscriptionService.shared.invalidateForAccountChange()
        },
        register: {
          await NeedsMeCloudKitSubscriptionService.shared.registerIfNeeded()
          await MobileCloudMirrorSubscriptionService.shared.registerIfNeeded()
        },
        onChange: {
          WidgetCenter.shared.reloadAllTimelines()
        }
      ),
      notificationCenter: .default,
      notificationName: .CKAccountChanged
    )
    super.init()
  }

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    application.registerForRemoteNotifications()
    Task.detached {
      await NeedsMeCloudKitSubscriptionService.shared.registerIfNeeded()
      await MobileCloudMirrorSubscriptionService.shared.registerIfNeeded()
    }
    accountObserver.start()
    return true
  }

  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    Task {
      let result = await MobileCloudMirrorBackgroundRefresher().refresh()
      await MobileBackgroundMirrorNotificationDispatcher().scheduleNotifications(for: result)
      await MainActor.run {
        NotificationCenter.default.post(name: .mobileMirrorRemoteRefreshRequested, object: nil)
        WidgetCenter.shared.reloadAllTimelines()
        completionHandler(result.didRefresh ? .newData : .noData)
      }
    }
  }
}
