import CloudKit
import HarnessMonitorCloudKit
import SwiftUI
import WatchKit
import WidgetKit

@main
struct HarnessMonitorWatchApp: App {
  @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
  private var accountObserver: NSObjectProtocol?

  func applicationDidFinishLaunching() {
    WKExtension.shared().registerForRemoteNotifications()
    Task.detached {
      await NeedsMeCloudKitSubscriptionService.shared.registerIfNeeded()
    }
    accountObserver = NotificationCenter.default.addObserver(
      forName: .CKAccountChanged,
      object: nil,
      queue: nil
    ) { _ in
      Task.detached {
        await NeedsMeCloudKitSubscriptionService.shared.invalidateForAccountChange()
        await NeedsMeCloudKitSubscriptionService.shared.registerIfNeeded()
        WidgetCenter.shared.reloadAllTimelines()
      }
    }
  }

  func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> WKBackgroundFetchResult {
    do {
      _ = try await NeedsMeCloudKitStore.shared.fetchCurrent()
    } catch {
      // best-effort refresh; widgets fall back to scheduled polling below
    }
    WidgetCenter.shared.reloadAllTimelines()
    return .newData
  }
}
