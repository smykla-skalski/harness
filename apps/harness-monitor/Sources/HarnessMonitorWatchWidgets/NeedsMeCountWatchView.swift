import SwiftUI
import WidgetKit

struct NeedsMeCountWatchView: View {
  let entry: NeedsMeCountTimelineEntry

  @Environment(\.widgetFamily)
  private var widgetFamily

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
      Image(systemName: "rectangle.stack.badge.person.crop")
        .font(.caption2)
      Text(verbatim: countLabel)
        .font(.title3)
        .fontWeight(.semibold)
        .minimumScaleFactor(0.6)
    }
    .widgetURL(URL(string: "harness-watch://reviews"))
  }

  private var rectangularView: some View {
    VStack(alignment: .leading, spacing: 2) {
      Label {
        Text("Needs you")
      } icon: {
        Image(systemName: "rectangle.stack.badge.person.crop")
      }
      .font(.caption2)
      Text(headlineText)
        .font(.headline)
      if let updatedAt = entry.updatedAt {
        Text(updatedAt, format: .relative(presentation: .numeric))
          .font(.caption2)
          .foregroundStyle(.secondary)
      } else {
        Text("Not synced yet")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .widgetURL(URL(string: "harness-watch://reviews"))
  }

  private var inlineView: some View {
    Text(inlineText)
      .widgetURL(URL(string: "harness-watch://reviews"))
  }

  private var countLabel: String {
    entry.updatedAt == nil ? "--" : String(entry.count)
  }

  private var headlineText: String {
    guard entry.updatedAt != nil else {
      return "-- reviews"
    }
    return "\(entry.count) review\(entry.count == 1 ? "" : "s")"
  }

  private var inlineText: String {
    guard entry.updatedAt != nil else {
      return "-- reviews need you"
    }
    let noun = entry.count == 1 ? "review" : "reviews"
    let verb = entry.count == 1 ? "needs" : "need"
    return "\(entry.count) \(noun) \(verb) you"
  }
}
