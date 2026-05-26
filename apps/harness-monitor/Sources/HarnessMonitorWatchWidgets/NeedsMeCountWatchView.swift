import HarnessMonitorCloudKit
import SwiftUI
import WidgetKit

struct NeedsMeCountWatchView: View {
  let entry: NeedsMeCountTimelineEntry

  @Environment(\.widgetFamily)
  private var widgetFamily

  static let staleAfter: TimeInterval = NeedsMeStalenessClassifier.defaultThreshold

  private var presentation: NeedsMeCountWatchPresentation {
    NeedsMeCountWatchPresentation(
      count: entry.count,
      updatedAt: entry.updatedAt,
      state: entry.state
    )
  }

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
    let pres = presentation
    return VStack(spacing: 2) {
      Image(systemName: pres.circularSymbolName)
        .font(.caption2)
        .foregroundStyle(pres.circularSymbolTone.swiftUIColor)
      Text(verbatim: pres.countLabel)
        .font(.title3)
        .fontWeight(.semibold)
        .minimumScaleFactor(0.6)
        .foregroundStyle(pres.countTone.swiftUIColor)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(pres.inlineText)
    .widgetURL(URL(string: "harness://reviews"))
  }

  private var rectangularView: some View {
    let pres = presentation
    return VStack(alignment: .leading, spacing: 2) {
      Label {
        Text(pres.rectangularTopLabel)
      } icon: {
        Image(systemName: "rectangle.stack.badge.person.crop")
      }
      .font(.caption2)
      Text(pres.rectangularHeadline)
        .font(.headline)
        .foregroundStyle(pres.countTone.swiftUIColor)
      Text(pres.rectangularSubtitle)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .widgetURL(URL(string: "harness://reviews"))
  }

  private var inlineView: some View {
    Text(presentation.inlineText)
      .widgetURL(URL(string: "harness://reviews"))
  }
}

extension WatchTone {
  var swiftUIColor: Color {
    switch self {
    case .primary: return .primary
    case .secondary: return .secondary
    case .warning: return .orange
    case .staleAccent: return .yellow
    }
  }
}
