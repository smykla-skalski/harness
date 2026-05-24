import CloudKit
import Combine
import Foundation

@MainActor
public final class CloudKitAccountChangeObserver {
  private let handler: CloudKitAccountChangeHandler
  private let notificationCenter: NotificationCenter
  private let notificationName: Notification.Name
  private var subscriptions: Set<AnyCancellable> = []

  public init(
    handler: CloudKitAccountChangeHandler,
    notificationCenter: NotificationCenter = .default,
    notificationName: Notification.Name = .CKAccountChanged
  ) {
    self.handler = handler
    self.notificationCenter = notificationCenter
    self.notificationName = notificationName
  }

  public func start() {
    guard subscriptions.isEmpty else { return }
    notificationCenter
      .publisher(for: notificationName)
      .receive(on: DispatchQueue.main)
      .sink { [handler] _ in
        Task.detached {
          await handler.handle()
        }
      }
      .store(in: &subscriptions)
  }

  public func stop() {
    subscriptions.removeAll()
  }
}
