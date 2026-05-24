import HarnessMonitorCloudKit
import SwiftUI
import WatchKit
import WidgetKit

@main
struct HarnessMonitorWatchApp: App {
  @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
  @State private var store = WatchMonitorStore()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(store)
    }
  }
}

@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
  private let accountObserver = CloudKitAccountChangeObserver(
    handler: CloudKitAccountChangeHandler.live(onChange: {
      WidgetCenter.shared.reloadAllTimelines()
    })
  )

  func applicationDidFinishLaunching() {
    WKExtension.shared().registerForRemoteNotifications()
    Task.detached {
      await NeedsMeCloudKitSubscriptionService.shared.registerIfNeeded()
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
    WidgetCenter.shared.reloadAllTimelines()
    return .newData
  }
}
