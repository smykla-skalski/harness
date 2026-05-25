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
    countTone = Self.countTone(state: state, isStale: isStale)
    circularSymbolName = Self.circularSymbolName(state: state)
    circularSymbolTone = Self.circularSymbolTone(state: state, isStale: isStale)
    rectangularTopLabel = Self.rectangularTopLabel(state: state)
    rectangularHeadline = Self.rectangularHeadline(count: count, hasData: hasData, state: state)
    rectangularSubtitle = Self.rectangularSubtitle(
      state: state,
      hasData: hasData,
      relative: relative,
      staleOrRelative: staleOrRelative,
      isStale: isStale
    )
    inlineText = Self.inlineText(count: count, hasData: hasData, state: state, isStale: isStale)
  }

  private static func relative(updatedAt: Date?, now: Date) -> String {
    guard let updatedAt else { return "Not synced yet" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    formatter.dateTimeStyle = .numeric
    return formatter.localizedString(for: updatedAt, relativeTo: now)
  }

  private static func countTone(state: NeedsMeCountState, isStale: Bool) -> WatchTone {
    switch state {
    case .notAuthenticated, .offline, .unknownError:
      .secondary
    case .cached, .live:
      isStale ? .secondary : .primary
    }
  }

  private static func circularSymbolName(state: NeedsMeCountState) -> String {
    switch state {
    case .notAuthenticated:
      "icloud.slash"
    case .offline, .unknownError:
      "wifi.slash"
    case .cached:
      "clock.arrow.circlepath"
    case .live:
      "rectangle.stack.badge.person.crop"
    }
  }

  private static func circularSymbolTone(state: NeedsMeCountState, isStale: Bool) -> WatchTone {
    switch state {
    case .notAuthenticated, .offline, .unknownError:
      .warning
    case .cached:
      .staleAccent
    case .live:
      isStale ? .staleAccent : .primary
    }
  }

  private static func rectangularTopLabel(state: NeedsMeCountState) -> String {
    switch state {
    case .notAuthenticated:
      "iCloud sign-in needed"
    case .offline:
      "Offline"
    case .unknownError:
      "Sync failed"
    case .cached:
      "Cached"
    case .live:
      "Needs you"
    }
  }

  private static func rectangularHeadline(
    count: Int,
    hasData: Bool,
    state: NeedsMeCountState
  ) -> String {
    guard hasData else {
      switch state {
      case .notAuthenticated:
        return "Sign in"
      case .offline, .unknownError:
        return "No data"
      case .cached, .live:
        return "-- reviews"
      }
    }
    return "\(count) review\(count == 1 ? "" : "s")"
  }

  private static func rectangularSubtitle(
    state: NeedsMeCountState,
    hasData: Bool,
    relative: String,
    staleOrRelative: String,
    isStale: Bool
  ) -> String {
    switch state {
    case .notAuthenticated:
      "Open the Mac app to refresh"
    case .offline:
      hasData ? staleOrRelative : "Connect to retry"
    case .unknownError:
      hasData ? staleOrRelative : "Retry shortly"
    case .cached:
      "May be outdated · \(relative)"
    case .live:
      isStale ? "May be outdated · \(relative)" : relative
    }
  }

  private static func inlineText(
    count: Int,
    hasData: Bool,
    state: NeedsMeCountState,
    isStale: Bool
  ) -> String {
    guard hasData else {
      switch state {
      case .notAuthenticated:
        return "Sign in to iCloud"
      case .offline, .unknownError:
        return "-- reviews (offline)"
      case .cached, .live:
        return "-- reviews need you"
      }
    }
    let noun = count == 1 ? "review" : "reviews"
    let verb = count == 1 ? "needs" : "need"
    let prefix = (isStale || state == .cached) ? "~" : ""
    return "\(prefix)\(count) \(noun) \(verb) you"
  }
}
