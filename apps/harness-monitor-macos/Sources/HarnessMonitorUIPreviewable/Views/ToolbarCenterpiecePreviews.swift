import SwiftUI

#Preview("Centerpiece - In Toolbar") {
  NavigationSplitView {
    List { Text("Sidebar") }
      .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
  } detail: {
    Text("Detail content")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  .toolbar {
    ContentCenterpieceToolbar(
      model: ToolbarCenterpieceModel(
        workspaceName: "Harness Monitor",
        destinationName: "My Mac",
        destinationSystemImage: "laptopcomputer"
      ),
      displayMode: .compact,
      statusMessages: [
        .init(text: "Running Harness Monitor", systemImage: "gearshape.fill", tint: .blue),
        .init(
          text: "3 sessions active", systemImage: "antenna.radiowaves.left.and.right", tint: .green),
        .init(text: "Daemon connected", systemImage: "checkmark.circle.fill", tint: .green),
      ]
    )
  }
  .frame(width: 900, height: 400)
}

#Preview("Centerpiece - All Modes") {
  let demoMessages: [ToolbarStatusMessage] = [
    .init(text: "Running Harness Monitor", systemImage: "gearshape.fill", tint: .blue),
    .init(text: "Daemon connected", systemImage: "checkmark.circle.fill", tint: .green),
  ]
  VStack(spacing: 24) {
    ForEach(
      Array(
        [
          ("Standard", ToolbarCenterpieceDisplayMode.standard),
          ("Compact", ToolbarCenterpieceDisplayMode.compact),
          ("Compressed", ToolbarCenterpieceDisplayMode.compressed),
        ].enumerated()
      ),
      id: \.offset
    ) { _, pair in
      VStack(spacing: 4) {
        Text(pair.0)
          .font(.caption)
          .foregroundStyle(.secondary)
        ToolbarCenterpieceView(
          model: .preview,
          displayMode: pair.1,
          statusMessages: demoMessages
        )
        .background(.quaternary, in: Capsule())
      }
    }
  }
  .padding(24)
}
