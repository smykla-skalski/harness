import CloudKit
import Combine
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

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
  private var subscriptions: Set<AnyCancellable> = []
  private let accountHandler = CloudKitAccountChangeHandler.live(onChange: {
    WidgetCenter.shared.reloadAllTimelines()
  })

  func applicationDidFinishLaunching() {
    WKExtension.shared().registerForRemoteNotifications()
    Task.detached {
      await NeedsMeCloudKitSubscriptionService.shared.registerIfNeeded()
    }
    NotificationCenter.default
      .publisher(for: .CKAccountChanged)
      .receive(on: DispatchQueue.main)
      .sink { [accountHandler] _ in
        Task.detached {
          await accountHandler.handle()
        }
      }
      .store(in: &subscriptions)
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
