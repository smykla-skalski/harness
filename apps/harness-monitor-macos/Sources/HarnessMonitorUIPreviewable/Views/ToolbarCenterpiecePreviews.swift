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
        destinationSystemImage: "laptopcomputer",
        metrics: [
          .init(kind: .projects, value: 11),
          .init(kind: .sessions, value: 1),
          .init(kind: .openWork, value: 4),
          .init(kind: .blocked, value: 1),
        ]
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

#Preview("Centerpiece - Varying Metrics") {
  VStack(spacing: 16) {
    ToolbarCenterpieceView(
      model: ToolbarCenterpieceModel(
        workspaceName: "Harness Monitor",
        destinationName: "My Mac",
        destinationSystemImage: "laptopcomputer",
        metrics: [
          .init(kind: .projects, value: 1),
          .init(kind: .blocked, value: 0),
        ]
      ),
      displayMode: .compact
    )
    .background(.quaternary, in: Capsule())

    ToolbarCenterpieceView(
      model: ToolbarCenterpieceModel(
        workspaceName: "Harness Monitor",
        destinationName: "My Mac",
        destinationSystemImage: "laptopcomputer",
        metrics: [
          .init(kind: .projects, value: 11),
          .init(kind: .sessions, value: 1),
          .init(kind: .openWork, value: 4),
          .init(kind: .blocked, value: 1),
        ]
      ),
      displayMode: .compact
    )
    .background(.quaternary, in: Capsule())

    ToolbarCenterpieceView(
      model: ToolbarCenterpieceModel(
        workspaceName: "Harness Monitor",
        destinationName: "My Mac",
        destinationSystemImage: "laptopcomputer",
        metrics: ToolbarCenterpieceMetricKind.allCases.map {
          .init(kind: $0, value: 999)
        }
      ),
      displayMode: .compact
    )
    .background(.quaternary, in: Capsule())
  }
  .padding(24)
}
