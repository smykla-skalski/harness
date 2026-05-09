import SwiftUI

#Preview("Session sidebar row") {
  SessionSidebarRowPreviewContent()
    .padding()
    .frame(width: 260)
}

#Preview("Session sidebar row - Largest text") {
  SessionSidebarRowPreviewContent()
    .environment(
      \.fontScale,
      HarnessMonitorTextSize.scale(at: HarnessMonitorTextSize.scales.count - 1)
    )
    .padding()
    .frame(width: 260)
}

struct SessionSidebarRowPreviewContent: View {
  var body: some View {
    SessionSidebarRow(
      title: "Workers",
      systemImage: "person.crop.circle",
      severityShape: .dot,
      severityTint: .orange
    ) { metrics in
      SessionSidebarDragHandle(metrics: metrics)
    }
  }
}
