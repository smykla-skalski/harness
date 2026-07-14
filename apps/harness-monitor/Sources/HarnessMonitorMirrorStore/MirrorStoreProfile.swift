import Foundation

/// Per-platform constants the shared store stamps onto commands and demo data.
/// The iOS app uses `.phone`; the watch uses `.watch`.
public struct MirrorStoreProfile: Equatable, Sendable {
  public var commandIDPrefix: String
  public var demoActorDeviceID: String
  public var pullRequestMergeAuditReason: String
  public var commandExpiry: TimeInterval

  public init(
    commandIDPrefix: String,
    demoActorDeviceID: String,
    pullRequestMergeAuditReason: String,
    commandExpiry: TimeInterval
  ) {
    self.commandIDPrefix = commandIDPrefix
    self.demoActorDeviceID = demoActorDeviceID
    self.pullRequestMergeAuditReason = pullRequestMergeAuditReason
    self.commandExpiry = commandExpiry
  }

  public static let phone = Self(
    commandIDPrefix: "command-",
    demoActorDeviceID: "device-demo-phone",
    pullRequestMergeAuditReason: "Confirmed from iPhone.",
    commandExpiry: 15 * 60
  )

  public static let watch = Self(
    commandIDPrefix: "watch-command-",
    demoActorDeviceID: "device-demo-watch",
    pullRequestMergeAuditReason: "Confirmed from Apple Watch.",
    commandExpiry: 10 * 60
  )
}
