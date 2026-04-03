import SwiftUI

struct ContentCenterpieceToolbar: ToolbarContent {
  let model: ToolbarCenterpieceModel
  let displayMode: ToolbarCenterpieceDisplayMode

  init(
    model: ToolbarCenterpieceModel = .preview,
    displayMode: ToolbarCenterpieceDisplayMode = .standard
  ) {
    self.model = model
    self.displayMode = displayMode
  }

  var body: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      ToolbarCenterpieceView(model: model, displayMode: displayMode)
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
  case sessions
  case openWork
  case blocked

  var accessibilityKey: String {
    switch self {
    case .projects:
      "projects"
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

  var minimumWidth: CGFloat {
    0
  }

  var idealWidth: CGFloat {
    switch self {
    case .standard:
      268
    case .compact:
      228
    case .compressed:
      182
    }
  }

  var maximumWidth: CGFloat {
    switch self {
    case .standard:
      324
    case .compact:
      268
    case .compressed:
      212
    }
  }

  var horizontalInset: CGFloat {
    switch self {
    case .standard:
      2
    case .compact:
      2
    case .compressed:
      1
    }
  }

  var interSectionSpacing: CGFloat {
    switch self {
    case .standard:
      HarnessMonitorTheme.spacingLG
    case .compact:
      6
    case .compressed:
      HarnessMonitorTheme.spacingXS
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
  private static let toolbarHeight: CGFloat = 32

  var body: some View {
    content
    .frame(
      minWidth: displayMode.minimumWidth,
      idealWidth: displayMode.idealWidth,
      maxWidth: displayMode.maximumWidth,
      minHeight: Self.toolbarHeight,
      idealHeight: Self.toolbarHeight,
      maxHeight: Self.toolbarHeight,
      alignment: .center
    )
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier(HarnessMonitorAccessibility.toolbarCenterpiece)
    .accessibilityLabel(model.accessibilityLabel)
    .accessibilityValue(model.accessibilityValue)
    .help("Live harness summary")
  }

  private var content: some View {
    ToolbarCenterpieceMetricsRow(metrics: model.metrics, displayMode: displayMode)
      .layoutPriority(1)
    .padding(.horizontal, displayMode.horizontalInset)
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
          .scaledFont(.caption.weight(.bold))
          .foregroundStyle(metric.kind.tint)
          .accessibilityHidden(true)
      }

      Text("\(metric.value)")
        .scaledFont(.system(.subheadline, design: .rounded, weight: .bold).monospacedDigit())
        .foregroundStyle(metric.kind.tint)
        .contentTransition(.numericText())

      if displayMode.showsMetricLabels {
        Text(labelText)
          .scaledFont(.caption2.weight(.bold))
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

#Preview("Toolbar Centerpiece - Standard") {
  toolbarCenterpiecePreview(displayMode: .standard)
}

#Preview("Toolbar Centerpiece - Compact") {
  toolbarCenterpiecePreview(displayMode: .compact)
}

#Preview("Toolbar Centerpiece - Compressed") {
  toolbarCenterpiecePreview(displayMode: .compressed)
}

private func toolbarCenterpiecePreview(
  displayMode: ToolbarCenterpieceDisplayMode
) -> some View {
  ToolbarCenterpieceView(
    model: ToolbarCenterpieceModel(
      workspaceName: "Harness Monitor",
      destinationName: "My Mac",
      destinationSystemImage: "laptopcomputer",
      metrics: [
        .init(kind: .projects, value: 6),
        .init(kind: .sessions, value: 24),
        .init(kind: .openWork, value: 13),
        .init(kind: .blocked, value: 3),
      ]
    ),
    displayMode: displayMode
  )
  .padding(.horizontal, 16)
  .padding(.vertical, 12)
  .frame(width: displayMode.maximumWidth + 32)
}
