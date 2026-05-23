import SwiftUI
import WidgetKit

struct NeedsMeCountWatchWidget: Widget {
    let kind: String = "needs-me-count-watch"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NeedsMeCountWatchProvider()) { entry in
            NeedsMeCountWatchView(entry: entry)
        }
        .configurationDisplayName("Needs Me")
        .description("How many pull requests need your review.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
