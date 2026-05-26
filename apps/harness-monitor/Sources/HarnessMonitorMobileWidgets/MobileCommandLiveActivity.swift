import ActivityKit
import HarnessMonitorCore
import SwiftUI
import WidgetKit

struct MobileCommandLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: MobileCommandActivityAttributes.self) { context in
      VStack(alignment: .leading, spacing: 6) {
        Label(context.attributes.commandTitle, systemImage: context.attributes.systemImageName)
          .font(.headline)
        Text(context.state.status)
          .font(.subheadline.weight(.semibold))
        Text("\(context.attributes.stationName)  \(context.state.detail)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
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
        Image(systemName: context.attributes.systemImageName)
          .accessibilityLabel(context.attributes.commandTitle)
      } compactTrailing: {
        Text(context.state.status.prefix(1))
          .accessibilityLabel(context.state.status)
      } minimal: {
        Image(systemName: context.attributes.systemImageName)
          .accessibilityLabel(context.attributes.commandTitle)
      }
    }
  }
}
