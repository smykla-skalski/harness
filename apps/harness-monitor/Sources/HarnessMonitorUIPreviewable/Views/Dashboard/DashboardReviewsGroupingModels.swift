import HarnessMonitorKit

struct DashboardReviewsItemGroup: Equatable, Identifiable, Sendable {
  enum Kind: Equatable, Sendable {
    case pinned
    case repository(String)
    case status(String)
    case author(String)
    case smartInbox(DashboardReviewsSmartInboxSection)

    var title: String {
      switch self {
      case .pinned: "Pinned"
      case .repository(let value): value
      case .status(let value): value
      case .author(let value): value
      case .smartInbox(let section): section.title
      }
    }

    var rawValue: String {
      switch self {
      case .pinned: "pinned"
      case .repository(let value): "repository:\(value)"
      case .status(let value): "status:\(value)"
      case .author(let value): "author:\(value)"
      case .smartInbox(let section): "smartInbox:\(section.rawValue)"
      }
    }
  }

  let kind: Kind
  let items: [ReviewItem]

  var id: String { kind.rawValue }

  // Back-compat accessor for callers that only handle repository groups.
  var repository: String {
    if case .repository(let value) = kind { return value }
    return ""
  }
}

typealias DashboardReviewsRepositoryGroup = DashboardReviewsItemGroup

enum DashboardReviewsSmartInboxSection: String, Equatable, Sendable {
  case primaryInbox
  case monitoring
  case dependencies
  case snoozed

  var title: String {
    switch self {
    case .primaryInbox: "Primary Inbox"
    case .monitoring: "Monitoring"
    case .dependencies: "Dependencies"
    case .snoozed: "Snoozed"
    }
  }

  var secondaryQueue: DashboardReviewsSecondaryQueue? {
    switch self {
    case .primaryInbox, .monitoring:
      nil
    case .dependencies:
      .dependencies
    case .snoozed:
      .snoozed
    }
  }
}
