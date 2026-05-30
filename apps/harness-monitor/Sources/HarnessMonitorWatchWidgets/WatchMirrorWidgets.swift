import HarnessMonitorCore
import SwiftUI
import WidgetKit

private enum WatchMirrorWidgetKind {
  case needsYou
  case stationHealth
  case commandQueue
}

struct WatchNeedsYouWidget: Widget {
  static let kind = "watch-needs-you"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: WatchMirrorTimelineProvider()) { entry in
      WatchMirrorWidgetView(entry: entry, kind: .needsYou)
    }
    .configurationDisplayName("Needs you")
    .description("Critical Harness Monitor work waiting for you")
    .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
  }
}

struct WatchStationHealthWidget: Widget {
  static let kind = "watch-station-health"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: WatchMirrorTimelineProvider()) { entry in
      WatchMirrorWidgetView(entry: entry, kind: .stationHealth)
    }
    .configurationDisplayName("Station health")
    .description("Paired Mac relay health")
    .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
  }
}

struct WatchCommandQueueWidget: Widget {
  static let kind = "watch-command-queue"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: WatchMirrorTimelineProvider()) { entry in
      WatchMirrorWidgetView(entry: entry, kind: .commandQueue)
    }
    .configurationDisplayName("Command Queue")
    .description("Queued and running remote commands")
    .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
  }
}

private struct WatchMirrorWidgetView: View {
  let entry: WatchMirrorTimelineEntry
  let kind: WatchMirrorWidgetKind

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
    .widgetURL(URL(string: widgetURLString))
  }

  private var circularView: some View {
    VStack(spacing: 2) {
      Image(systemName: symbolName)
        .font(.caption2)
        .foregroundStyle(tint)
      Text(valueText)
        .font(.title3.weight(.semibold))
        .minimumScaleFactor(0.55)
        .monospacedDigit()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(inlineText)
  }

  private var rectangularView: some View {
    VStack(alignment: .leading, spacing: 2) {
      Label(title, systemImage: symbolName)
        .font(.caption2)
        .foregroundStyle(tint)
      Text(headline)
        .font(.headline)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
      Text(subtitle)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
    .accessibilityElement(children: .combine)
  }

  private var inlineView: some View {
    Label(inlineText, systemImage: symbolName)
  }

  private var title: String {
    switch kind {
    case .needsYou: String(localized: "Needs you")
    case .stationHealth: String(localized: "Stations")
    case .commandQueue: String(localized: "Commands")
    }
  }

  private var widgetURLString: String {
    switch kind {
    case .commandQueue:
      "harness://commands"
    case .needsYou, .stationHealth:
      "harness://today"
    }
  }

  private var valueText: String {
    switch kind {
    case .needsYou:
      "\(entry.snapshot.needsYouCount)"
    case .stationHealth:
      "\(onlineStationCount)"
    case .commandQueue:
      "\(activeCommandCount)"
    }
  }

  private var headline: String {
    switch kind {
    case .needsYou:
      if entry.snapshot.needsYouCount == 0 {
        String(localized: "All clear")
      } else {
        String(localized: "\(entry.snapshot.needsYouCount) waiting")
      }
    case .stationHealth:
      if entry.snapshot.stations.isEmpty {
        entry.state.shortTitle
      } else {
        String(localized: "\(onlineStationCount)/\(entry.snapshot.stations.count) online")
      }
    case .commandQueue:
      if activeCommandCount == 0 {
        String(localized: "No active commands")
      } else {
        String(localized: "\(activeCommandCount) active")
      }
    }
  }

  private var subtitle: String {
    switch kind {
    case .needsYou:
      entry.snapshot.sortedAttention.first?.title ?? entry.state.shortTitle
    case .stationHealth:
      mostImportantStation?.displayName ?? entry.state.shortTitle
    case .commandQueue:
      entry.snapshot.commands.first?.title ?? entry.state.shortTitle
    }
  }

  private var inlineText: String {
    switch kind {
    case .needsYou:
      if entry.snapshot.needsYouCount == 0 {
        String(localized: "Needs You clear")
      } else {
        String(localized: "\(entry.snapshot.needsYouCount) need you")
      }
    case .stationHealth:
      if entry.snapshot.stations.isEmpty {
        String(localized: "Stations \(entry.state.shortTitle)")
      } else {
        String(
          localized: "\(onlineStationCount)/\(entry.snapshot.stations.count) stations online")
      }
    case .commandQueue:
      if activeCommandCount == 0 {
        String(localized: "Commands clear")
      } else {
        String(localized: "\(activeCommandCount) commands active")
      }
    }
  }

  private var symbolName: String {
    switch kind {
    case .needsYou:
      entry.snapshot.needsYouCount == 0 ? "checkmark.circle" : "dot.radiowaves.left.and.right"
    case .stationHealth:
      stationSymbolName
    case .commandQueue:
      activeCommandCount == 0 ? "checkmark.seal" : "terminal"
    }
  }

  private var tint: Color {
    switch kind {
    case .needsYou:
      entry.snapshot.needsYouCount == 0 ? .green : .red
    case .stationHealth:
      stationTint
    case .commandQueue:
      activeCommandCount == 0 ? .green : .orange
    }
  }

  private var onlineStationCount: Int {
    entry.snapshot.stations.filter { $0.state == .online }.count
  }

  private var activeCommandCount: Int {
    entry.snapshot.commands.filter { $0.isActiveMobileQueueCommand(now: entry.date) }.count
  }

  private var mostImportantStation: MobileStationSummary? {
    entry.snapshot.stations.min {
      if $0.state.priority != $1.state.priority {
        return $0.state.priority < $1.state.priority
      }
      return $0.lastSeenAt > $1.lastSeenAt
    }
  }

  private var stationSymbolName: String {
    switch mostImportantStation?.state {
    case .online:
      "desktopcomputer"
    case .stale:
      "desktopcomputer.trianglebadge.exclamationmark"
    case .offline:
      "wifi.slash"
    case nil:
      "link.badge.plus"
    }
  }

  private var stationTint: Color {
    switch mostImportantStation?.state {
    case .online:
      .green
    case .stale:
      .orange
    case .offline:
      .red
    case nil:
      .secondary
    }
  }
}

extension MobileStationState {
  fileprivate var priority: Int {
    switch self {
    case .offline: 0
    case .stale: 1
    case .online: 2
    }
  }
}
