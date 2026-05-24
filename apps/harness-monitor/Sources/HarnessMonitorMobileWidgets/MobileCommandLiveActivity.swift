import ActivityKit
import SwiftUI
import WidgetKit

public struct MobileCommandActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    public var status: String
    public var detail: String

    public init(status: String, detail: String) {
      self.status = status
      self.detail = detail
    }
  }

  public var commandTitle: String
  public var stationName: String

  public init(commandTitle: String, stationName: String) {
    self.commandTitle = commandTitle
    self.stationName = stationName
  }
}

struct MobileCommandLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: MobileCommandActivityAttributes.self) { context in
      VStack(alignment: .leading, spacing: 6) {
        Label(context.attributes.commandTitle, systemImage: "terminal")
          .font(.headline)
        Text(context.state.status)
          .font(.subheadline.weight(.semibold))
        Text("\(context.attributes.stationName)  \(context.state.detail)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding()
      .activityBackgroundTint(.black.opacity(0.08))
      .activitySystemActionForegroundColor(.accentColor)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text(context.attributes.stationName)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.status)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(context.attributes.commandTitle)
            .lineLimit(1)
        }
      } compactLeading: {
        Image(systemName: "terminal")
      } compactTrailing: {
        Text(context.state.status.prefix(1))
      } minimal: {
        Image(systemName: "terminal")
      }
    }
  }
}
