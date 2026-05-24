import SwiftUI
import WidgetKit

struct NeedsMeCountWatchView: View {
  let entry: NeedsMeCountTimelineEntry

  @Environment(\.widgetFamily)
  private var widgetFamily

  static let staleAfter: TimeInterval = 60 * 60

  var body: some View {
    Group {
      switch widgetFamily {
      case .accessoryCircular:
        circularView
      case .accessoryRectangular:
        rectangularView
      case .accessoryInline:
        inlineView
      default:
        inlineView
      }
    }
    .containerBackground(.clear, for: .widget)
  }

  private var circularView: some View {
    VStack(spacing: 2) {
      Image(systemName: circularSymbolName)
        .font(.caption2)
        .foregroundStyle(circularSymbolColor)
      Text(verbatim: countLabel)
        .font(.title3)
        .fontWeight(.semibold)
        .minimumScaleFactor(0.6)
        .foregroundStyle(countColor)
    }
    .widgetURL(URL(string: "harness-watch://reviews"))
  }

  private var rectangularView: some View {
    VStack(alignment: .leading, spacing: 2) {
      Label {
        Text(rectangularTopLabel)
      } icon: {
        Image(systemName: "rectangle.stack.badge.person.crop")
      }
      .font(.caption2)
      Text(headlineText)
        .font(.headline)
        .foregroundStyle(countColor)
      Text(rectangularSubtitle)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .widgetURL(URL(string: "harness-watch://reviews"))
  }

  private var inlineView: some View {
    Text(inlineText)
      .widgetURL(URL(string: "harness-watch://reviews"))
  }

  private var isStale: Bool {
    guard let updatedAt = entry.updatedAt else { return false }
    return Date().timeIntervalSince(updatedAt) > Self.staleAfter
  }

  private var countLabel: String {
    entry.updatedAt == nil ? "--" : String(entry.count)
  }

  private var countColor: Color {
    switch entry.state {
    case .notAuthenticated, .offline, .unknownError:
      return .secondary
    case .cached:
      return isStale ? .secondary : .primary
    case .live:
      return isStale ? .secondary : .primary
    }
  }

  private var circularSymbolName: String {
    switch entry.state {
    case .notAuthenticated: return "icloud.slash"
    case .offline, .unknownError: return "wifi.slash"
    case .cached: return "clock.arrow.circlepath"
    case .live: return "rectangle.stack.badge.person.crop"
    }
  }

  private var circularSymbolColor: Color {
    switch entry.state {
    case .notAuthenticated, .offline, .unknownError:
      return .orange
    case .cached:
      return .yellow
    case .live:
      return isStale ? .yellow : .primary
    }
  }

  private var rectangularTopLabel: String {
    switch entry.state {
    case .notAuthenticated: return "iCloud sign-in needed"
    case .offline: return "Offline"
    case .unknownError: return "Sync failed"
    case .cached: return "Cached"
    case .live: return "Needs you"
    }
  }

  private var headlineText: String {
    guard entry.updatedAt != nil else {
      switch entry.state {
      case .notAuthenticated: return "Sign in"
      case .offline, .unknownError: return "No data"
      default: return "-- reviews"
      }
    }
    return "\(entry.count) review\(entry.count == 1 ? "" : "s")"
  }

  private var rectangularSubtitle: String {
    switch entry.state {
    case .notAuthenticated:
      return "Open the Mac app to refresh"
    case .offline:
      return entry.updatedAt == nil ? "Connect to retry" : staleOrRelative
    case .unknownError:
      return entry.updatedAt == nil ? "Retry shortly" : staleOrRelative
    case .cached:
      return "May be outdated · \(relativeText)"
    case .live:
      return isStale ? "May be outdated · \(relativeText)" : relativeText
    }
  }

  private var staleOrRelative: String {
    isStale ? "May be outdated · \(relativeText)" : relativeText
  }

  private var relativeText: String {
    guard let updatedAt = entry.updatedAt else { return "Not synced yet" }
    return updatedAt.formatted(.relative(presentation: .numeric))
  }

  private var inlineText: String {
    guard entry.updatedAt != nil else {
      switch entry.state {
      case .notAuthenticated: return "Sign in to iCloud"
      case .offline, .unknownError: return "-- reviews (offline)"
      default: return "-- reviews need you"
      }
    }
    let noun = entry.count == 1 ? "review" : "reviews"
    let verb = entry.count == 1 ? "needs" : "need"
    let stalePrefix = (isStale || entry.state == .cached) ? "~" : ""
    return "\(stalePrefix)\(entry.count) \(noun) \(verb) you"
  }
}
