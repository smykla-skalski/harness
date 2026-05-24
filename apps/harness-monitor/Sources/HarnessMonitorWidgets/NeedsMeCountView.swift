import HarnessMonitorKit
import SwiftUI
import WidgetKit

struct NeedsMeCountView: View {
  let entry: NeedsMeCountEntry

  private var tapURL: URL? {
    HarnessMonitorDeepLinkRouter.url(for: .reviews(needsMeOn: true))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label("Needs Me", systemImage: "checklist.checked")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(entry.count, format: .number)
        .font(.system(size: 44, weight: .semibold, design: .rounded))
        .monospacedDigit()
      Text(footer)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .widgetURL(tapURL)
  }

  private var footer: String {
    entry.count == 1 ? "review waiting" : "reviews waiting"
  }
}
