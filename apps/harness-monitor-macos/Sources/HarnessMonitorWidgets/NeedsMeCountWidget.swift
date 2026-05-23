import SwiftUI
import WidgetKit

struct NeedsMeCountWidget: Widget {
  static let kind = "needs-me-count"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: NeedsMeCountProvider()) { entry in
      NeedsMeCountView(entry: entry)
        .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName("Needs-Me Count")
    .description("Pull requests waiting for your review.")
    .supportedFamilies([.systemSmall])
  }
}
