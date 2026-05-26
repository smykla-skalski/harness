import HarnessMonitorCloudKit
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorMirrorStore
import SwiftUI
import WatchKit
import WidgetKit

@main
struct HarnessMonitorWatchApp: App {
  @WKApplicationDelegateAdaptor(WatchAppDelegate.self)
  private var delegate
  @State private var store: MirrorStore
  private let pairingReceiver: WatchPairingSessionReceiver

  init() {
    let identityStore = KeychainMobileDeviceIdentityStore()
    let credentialStore = KeychainMobilePairedStationCredentialStore()
    _store = State(
      initialValue: MirrorStore(
        demoModeEnabled: Self.defaultDemoModeEnabled,
        profile: .watch,
        identityStore: identityStore,
        credentialStore: credentialStore,
        syncClientFactory: LiveMobileMonitorSyncClientFactory(
          actorDeviceID: { MobileCommandActorDeviceID.watchActorID(baseDeviceID: $0.id) }
        )
      )
    )
    pairingReceiver = WatchPairingSessionReceiver(
      identityStore: identityStore,
      credentialStore: credentialStore
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
      RootView()
        .environment(store)
        .task {
          store.requestFreshPairingMaterial = { [pairingReceiver] in
            pairingReceiver.requestPairingTransfer()
          }
          pairingReceiver.start {
            await store.loadTransferredPairings()
          }
        }
        .onReceive(
          NotificationCenter.default.publisher(for: .watchMirrorRemoteRefreshRequested)
        ) { _ in
          Task {
            await store.load()
          }
        }
    }
  }
}

@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
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

  func applicationDidFinishLaunching() {
    WKExtension.shared().registerForRemoteNotifications()
    if Self.shouldRegisterCloudKitSubscriptions {
      Task.detached {
        await NeedsMeCloudKitSubscriptionService.shared.registerIfNeeded()
        await MobileCloudMirrorSubscriptionService.shared.registerIfNeeded()
      }
    }
    accountObserver.start()
  }

  func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> WKBackgroundFetchResult
  {
    do {
      _ = try await NeedsMeCloudKitStore.shared.fetchCurrent()
    } catch {
      // best-effort refresh; widgets fall back to scheduled polling below
    }
    let result = await MobileCloudMirrorBackgroundRefresher().refresh()
    NotificationCenter.default.post(name: .watchMirrorRemoteRefreshRequested, object: nil)
    WidgetCenter.shared.reloadAllTimelines()
    return result.didRefresh ? .newData : .noData
  }
}

extension Notification.Name {
  static let watchMirrorRemoteRefreshRequested = Notification.Name(
    "io.harnessmonitor.watch.mirrorRemoteRefreshRequested"
  )
}
