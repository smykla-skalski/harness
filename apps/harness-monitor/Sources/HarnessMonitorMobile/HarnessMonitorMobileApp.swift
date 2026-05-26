import HarnessMonitorCloudKit
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorMirrorStore
import SwiftUI
import UIKit
@preconcurrency import UserNotifications
import WidgetKit

@main
struct HarnessMonitorMobileApp: App {
  @UIApplicationDelegateAdaptor(MobileAppDelegate.self)
  private var delegate
  @Environment(\.scenePhase)
  private var scenePhase
  @State private var store: MirrorStore
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
      initialValue: MirrorStore(
        demoModeEnabled: Self.defaultDemoModeEnabled,
        identityStore: identityStore,
        credentialStore: credentialStore,
        pairer: LiveMobileMonitorCredentialPairer(
          identityStore: identityStore,
          credentialStore: credentialStore
        ),
        watchPairingSyncer: watchPairingSyncer,
        liveActivityCoordinator: LiveMobileCommandLiveActivityCoordinator(),
        notificationScheduler: LiveMobileNotificationScheduler()
      )
    )
  }

  nonisolated private static var defaultDemoModeEnabled: Bool {
    #if targetEnvironment(simulator)
      true
    #else
      false
    #endif
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
        .onReceive(
          NotificationCenter.default.publisher(for: .mobileNotificationTabRequested)
        ) { notification in
          guard let navigation = notification.object as? MobileNotificationNavigation else {
            return
          }
          if let stationID = navigation.stationID, !stationID.isEmpty {
            store.selectedStationID = stationID
          }
          selectedTab = navigation.tab
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
  static let mobileNotificationTabRequested = Notification.Name(
    "io.harnessmonitor.mobile.notificationTabRequested"
  )
}

struct MobileNotificationNavigation {
  var tab: MobileRootTab
  var stationID: String?
}

@MainActor
final class MobileAppDelegate: NSObject, UIApplicationDelegate {
  private let accountObserver: CloudKitAccountChangeObserver
  nonisolated private static var shouldRegisterCloudKitSubscriptions: Bool {
    #if targetEnvironment(simulator)
      false
    #else
      true
    #endif
  }

  override init() {
    accountObserver = CloudKitAccountChangeObserver(
      handler: CloudKitAccountChangeHandler(
        invalidate: {
          guard Self.shouldRegisterCloudKitSubscriptions else {
            return
          }
          await NeedsMeCloudKitSubscriptionService.shared.invalidateForAccountChange()
          await MobileCloudMirrorSubscriptionService.shared.invalidateForAccountChange()
        },
        register: {
          guard Self.shouldRegisterCloudKitSubscriptions else {
            return
          }
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
    UNUserNotificationCenter.current().delegate = self
    application.registerForRemoteNotifications()
    if Self.shouldRegisterCloudKitSubscriptions {
      Task.detached {
        await NeedsMeCloudKitSubscriptionService.shared.registerIfNeeded()
        await MobileCloudMirrorSubscriptionService.shared.registerIfNeeded()
      }
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

extension MobileAppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    NotificationCenter.default.post(
      name: .mobileNotificationTabRequested,
      object: Self.navigation(for: response)
    )
    completionHandler()
  }

  private static func navigation(for response: UNNotificationResponse)
    -> MobileNotificationNavigation
  {
    let content = response.notification.request.content
    let stationID = content.userInfo["stationID"] as? String
    return MobileNotificationNavigation(
      tab: tab(for: content),
      stationID: stationID
    )
  }

  private static func tab(for content: UNNotificationContent) -> MobileRootTab {
    if let targetTab = content.userInfo["targetTab"] as? String,
      let tab = MobileRootTab(notificationDestination: targetTab)
    {
      return tab
    }
    return tab(forCategoryIdentifier: content.categoryIdentifier)
  }

  private static func tab(forCategoryIdentifier identifier: String) -> MobileRootTab {
    if identifier.contains(".commandStatus") || identifier.contains(".commandFailure") {
      return .commands
    }
    return .today
  }
}

extension MobileRootTab {
  fileprivate init?(notificationDestination value: String) {
    switch value {
    case MobileNotificationDestination.today.rawValue:
      self = .today
    case MobileNotificationDestination.sessions.rawValue:
      self = .sessions
    case MobileNotificationDestination.reviews.rawValue:
      self = .reviews
    case MobileNotificationDestination.commands.rawValue:
      self = .commands
    case MobileNotificationDestination.settings.rawValue:
      self = .settings
    default:
      return nil
    }
  }
}
