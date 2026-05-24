import CloudKit
import Foundation

public actor NeedsMeCloudKitSubscriptionService {
  public static let shared = NeedsMeCloudKitSubscriptionService()

  public static let subscriptionID = "needs-me-snapshot-changes"

  private var didRegisterThisSession = false

  public init() {}

  public func registerIfNeeded() async {
    guard !didRegisterThisSession else { return }
    didRegisterThisSession = true

    let database = CloudKitContainer.privateDatabase()
    let predicate = NSPredicate(value: true)
    let subscription = CKQuerySubscription(
      recordType: CloudKitContainer.recordType,
      predicate: predicate,
      subscriptionID: Self.subscriptionID,
      options: [
        .firesOnRecordCreation,
        .firesOnRecordUpdate,
        .firesOnRecordDeletion,
      ]
    )

    let notificationInfo = CKSubscription.NotificationInfo()
    notificationInfo.shouldSendContentAvailable = true
    subscription.notificationInfo = notificationInfo

    do {
      _ = try await database.save(subscription)
    } catch let error as CKError where error.code == .serverRejectedRequest {
      // Already registered — server rejects duplicate subscriptionID with this code.
    } catch {
      // Subscription registration is best-effort; silent push is not required for correctness.
      // The 15-min timeline polling cycle covers all cases.
    }
  }
}
