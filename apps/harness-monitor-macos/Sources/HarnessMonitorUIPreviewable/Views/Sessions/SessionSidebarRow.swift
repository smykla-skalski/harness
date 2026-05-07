import HarnessMonitorKit
import SwiftUI

struct SessionSidebarRow: View {
  let title: String
  let subtitle: String?
  let systemImage: String
  let badge: String?

  var body: some View {
    Label {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .lineLimit(1)
          if let subtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        if let badge {
          Text(badge)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    } icon: {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)
    }
  }
}
