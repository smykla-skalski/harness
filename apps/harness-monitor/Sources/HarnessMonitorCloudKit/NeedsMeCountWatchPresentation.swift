import Foundation

public enum WatchTone: Equatable, Sendable {
  case primary
  case secondary
  case warning
  case staleAccent
}

public struct NeedsMeCountWatchPresentation: Equatable, Sendable {
  public let countLabel: String
  public let countTone: WatchTone
  public let circularSymbolName: String
  public let circularSymbolTone: WatchTone
  public let rectangularTopLabel: String
  public let rectangularHeadline: String
  public let rectangularSubtitle: String
  public let inlineText: String

  public init(
    count: Int,
    updatedAt: Date?,
    state: NeedsMeCountState,
    now: Date = Date(),
    staleThreshold: TimeInterval = NeedsMeStalenessClassifier.defaultThreshold
  ) {
    let isStale = NeedsMeStalenessClassifier.isStale(
      updatedAt: updatedAt,
      now: now,
      threshold: staleThreshold
    )
    let hasData = updatedAt != nil
    let relative = Self.relative(updatedAt: updatedAt, now: now)
    let staleOrRelative = isStale ? "May be outdated · \(relative)" : relative

    countLabel = hasData ? String(count) : "--"

    switch state {
    case .notAuthenticated, .offline, .unknownError:
      countTone = .secondary
    case .cached, .live:
      countTone = isStale ? .secondary : .primary
    }

    switch state {
    case .notAuthenticated: circularSymbolName = "icloud.slash"
    case .offline, .unknownError: circularSymbolName = "wifi.slash"
    case .cached: circularSymbolName = "clock.arrow.circlepath"
    case .live: circularSymbolName = "rectangle.stack.badge.person.crop"
    }

    switch state {
    case .notAuthenticated, .offline, .unknownError: circularSymbolTone = .warning
    case .cached: circularSymbolTone = .staleAccent
    case .live: circularSymbolTone = isStale ? .staleAccent : .primary
    }

    switch state {
    case .notAuthenticated: rectangularTopLabel = "iCloud sign-in needed"
    case .offline: rectangularTopLabel = "Offline"
    case .unknownError: rectangularTopLabel = "Sync failed"
    case .cached: rectangularTopLabel = "Cached"
    case .live: rectangularTopLabel = "Needs you"
    }

    if hasData {
      rectangularHeadline = "\(count) review\(count == 1 ? "" : "s")"
    } else {
      switch state {
      case .notAuthenticated: rectangularHeadline = "Sign in"
      case .offline, .unknownError: rectangularHeadline = "No data"
      case .cached, .live: rectangularHeadline = "-- reviews"
      }
    }

    switch state {
    case .notAuthenticated:
      rectangularSubtitle = "Open the Mac app to refresh"
    case .offline:
      rectangularSubtitle = hasData ? staleOrRelative : "Connect to retry"
    case .unknownError:
      rectangularSubtitle = hasData ? staleOrRelative : "Retry shortly"
    case .cached:
      rectangularSubtitle = "May be outdated · \(relative)"
    case .live:
      rectangularSubtitle = isStale ? "May be outdated · \(relative)" : relative
    }

    if hasData {
      let noun = count == 1 ? "review" : "reviews"
      let verb = count == 1 ? "needs" : "need"
      let prefix = (isStale || state == .cached) ? "~" : ""
      inlineText = "\(prefix)\(count) \(noun) \(verb) you"
    } else {
      switch state {
      case .notAuthenticated: inlineText = "Sign in to iCloud"
      case .offline, .unknownError: inlineText = "-- reviews (offline)"
      case .cached, .live: inlineText = "-- reviews need you"
      }
    }
  }

  private static func relative(updatedAt: Date?, now: Date) -> String {
    guard let updatedAt else { return "Not synced yet" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    formatter.dateTimeStyle = .numeric
    return formatter.localizedString(for: updatedAt, relativeTo: now)
  }
}
