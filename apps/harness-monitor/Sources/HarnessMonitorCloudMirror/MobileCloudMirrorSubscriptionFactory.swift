import CloudKit

public struct MobileCloudMirrorSubscriptionFactory: Sendable {
  public init() {}

  public func makeZoneSubscription(
    zoneID: CKRecordZone.ID = MobileCloudMirrorCloudKitSchema.zoneID
  ) -> CKRecordZoneSubscription {
    let subscription = CKRecordZoneSubscription(
      zoneID: zoneID,
      subscriptionID: MobileCloudMirrorCloudKitSchema.subscriptionID
    )
    let notificationInfo = CKSubscription.NotificationInfo()
    notificationInfo.shouldSendContentAvailable = true
    subscription.notificationInfo = notificationInfo
    return subscription
  }
}
