import SwiftUI

struct ContentCenterpieceToolbar: ToolbarContent {
  let model: ToolbarCenterpieceModel
  let displayMode: ToolbarCenterpieceDisplayMode
  var statusMessages: [ToolbarStatusMessage] = []

  init(
    model: ToolbarCenterpieceModel = .preview,
    displayMode: ToolbarCenterpieceDisplayMode = .standard,
    statusMessages: [ToolbarStatusMessage] = []
  ) {
    self.model = model
    self.displayMode = displayMode
    self.statusMessages = statusMessages
  }

  var body: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      ToolbarCenterpieceView(
        model: model,
        displayMode: displayMode,
        statusMessages: statusMessages
      )
    }
  }
}

struct ToolbarCenterpieceModel: Equatable {
  let workspaceName: String
  let destinationName: String
  let destinationSystemImage: String
  let metrics: [ToolbarCenterpieceMetric]

  static let preview = Self(
    workspaceName: "Harness Monitor",
    destinationName: "My Mac",
    destinationSystemImage: "laptopcomputer",
    metrics: [
      .init(kind: .projects, value: 1),
      .init(kind: .sessions, value: 1),
      .init(kind: .openWork, value: 2),
      .init(kind: .blocked, value: 1),
    ]
  )

  var accessibilityLabel: String {
    "\(workspaceName), \(destinationName)"
  }

  var accessibilityValue: String {
    metrics
      .map { "\($0.kind.accessibilityKey)=\($0.value)" }
      .joined(separator: ", ")
  }
}

struct ToolbarCenterpieceMetric: Equatable {
  let kind: ToolbarCenterpieceMetricKind
  let value: Int
}

enum ToolbarCenterpieceMetricKind: String, CaseIterable {
  case projects
  case worktrees
  case sessions
  case openWork
  case blocked

  var accessibilityKey: String {
    switch self {
    case .projects:
      "projects"
    case .worktrees:
      "worktrees"
    case .sessions:
      "sessions"
    case .openWork:
      "openWork"
    case .blocked:
      "blocked"
    }
  }

  var title: String {
    switch self {
    case .projects:
      "Projects"
    case .worktrees:
      "Worktrees"
    case .sessions:
      "Sessions"
    case .openWork:
      "Open"
    case .blocked:
      "Blocked"
    }
  }

  var tint: Color {
    switch self {
    case .projects:
      HarnessMonitorTheme.accent
    case .worktrees:
      HarnessMonitorTheme.warmAccent
    case .sessions:
      HarnessMonitorTheme.success
    case .openWork:
      HarnessMonitorTheme.warmAccent
    case .blocked:
      HarnessMonitorTheme.danger
    }
  }

  var symbolName: String {
    switch self {
    case .projects:
      "folder.fill"
    case .worktrees:
      "square.3.layers.3d.down.right"
    case .sessions:
      "rectangle.stack.fill"
    case .openWork:
      "checklist"
    case .blocked:
      "exclamationmark.triangle.fill"
    }
  }
}

enum ToolbarCenterpieceDisplayMode: String {
  case standard
  case compact
  case compressed

  private static let standardWindowThreshold: CGFloat = 1_520
  private static let compactWindowThreshold: CGFloat = 1_320

  static func forWindowWidth(_ windowWidth: CGFloat) -> Self {
    switch windowWidth {
    case Self.standardWindowThreshold...:
      .standard
    case Self.compactWindowThreshold...:
      .compact
    default:
      .compressed
    }
  }

  var metricSpacing: CGFloat {
    switch self {
    case .standard:
      8
    case .compact:
      6
    case .compressed:
      4
    }
  }

  var showsMetricLabels: Bool { self == .standard }
}

private struct ToolbarCenterpieceView: View {
  let model: ToolbarCenterpieceModel
  let displayMode: ToolbarCenterpieceDisplayMode
  var statusMessages: [ToolbarStatusMessage] = []
  private static let toolbarHeight: CGFloat = 32
  private static let baseHorizontalPadding: CGFloat = 12

  private static let tickerWidth: CGFloat = 220
  private static let centerpieceWidth: CGFloat = 560

  var body: some View {
    HStack(spacing: 0) {
      ToolbarCenterpieceMetricsRow(metrics: model.metrics, displayMode: displayMode)
        .fixedSize(horizontal: true, vertical: false)

      if !statusMessages.isEmpty {
        Spacer(minLength: 20)

        ToolbarStatusTickerView(messages: statusMessages, direction: .up)
          .frame(width: Self.tickerWidth, alignment: .trailing)
      }
    }
    .padding(.horizontal, Self.baseHorizontalPadding)
    .frame(width: Self.centerpieceWidth)
    .frame(height: Self.toolbarHeight)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(HarnessMonitorAccessibility.toolbarCenterpiece)
    .accessibilityLabel(model.accessibilityLabel)
    .accessibilityValue(model.accessibilityValue)
    .help("Live harness summary")
  }
}

private struct ToolbarCenterpieceMetricsRow: View {
  let metrics: [ToolbarCenterpieceMetric]
  let displayMode: ToolbarCenterpieceDisplayMode

  var body: some View {
    HStack(spacing: displayMode.metricSpacing) {
      ForEach(metrics, id: \.kind.rawValue) { metric in
        ToolbarCenterpieceMetricToken(metric: metric, displayMode: displayMode)
      }
    }
  }
}

private struct ToolbarCenterpieceMetricToken: View {
  let metric: ToolbarCenterpieceMetric
  let displayMode: ToolbarCenterpieceDisplayMode

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      if !displayMode.showsMetricLabels {
        Image(systemName: metric.kind.symbolName)
          .font(.caption.weight(.bold))
          .foregroundStyle(metric.kind.tint)
          .accessibilityHidden(true)
      }

      Text("\(metric.value)")
        .font(.system(.subheadline, design: .rounded, weight: .bold).monospacedDigit())
        .foregroundStyle(metric.kind.tint)
        .contentTransition(.numericText())

      if displayMode.showsMetricLabels {
        Text(labelText)
          .font(.caption2.weight(.bold))
          .tracking(HarnessMonitorTheme.uppercaseTracking)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var labelText: String {
    metric.kind.title.uppercased()
  }
}

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
        .init(text: "3 sessions active", systemImage: "antenna.radiowaves.left.and.right", tint: .green),
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
