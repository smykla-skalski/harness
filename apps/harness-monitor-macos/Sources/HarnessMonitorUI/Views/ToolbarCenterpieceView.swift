import HarnessMonitorKit
import SwiftUI

enum ToolbarDaemonIndicator: Equatable {
  case offline
  case launchdConnected
  case manualConnected

  var foregroundColor: Color {
    switch self {
    case .offline:
      .secondary
    case .launchdConnected, .manualConnected:
      HarnessMonitorTheme.success
    }
  }
}

extension ToolbarDaemonIndicator {
  init(_ state: HarnessMonitorStore.DaemonIndicatorState) {
    switch state {
    case .offline:
      self = .offline
    case .launchdConnected:
      self = .launchdConnected
    case .manualConnected:
      self = .manualConnected
    }
  }
}

struct ContentCenterpieceToolbar: ToolbarContent {
  let model: ToolbarCenterpieceModel
  let displayMode: ToolbarCenterpieceDisplayMode
  let availableDetailWidth: CGFloat
  var statusMessages: [ToolbarStatusMessage] = []
  var daemonIndicator: ToolbarDaemonIndicator = .offline
  var store: HarnessMonitorStore?
  var connectionState: HarnessMonitorStore.ConnectionState = .idle
  var isBusy: Bool = false

  init(
    model: ToolbarCenterpieceModel = .preview,
    displayMode: ToolbarCenterpieceDisplayMode = .standard,
    availableDetailWidth: CGFloat = 1_024,
    statusMessages: [ToolbarStatusMessage] = [],
    daemonIndicator: ToolbarDaemonIndicator = .offline,
    store: HarnessMonitorStore? = nil,
    connectionState: HarnessMonitorStore.ConnectionState = .idle,
    isBusy: Bool = false
  ) {
    self.model = model
    self.displayMode = displayMode
    self.availableDetailWidth = availableDetailWidth
    self.statusMessages = statusMessages
    self.daemonIndicator = daemonIndicator
    self.store = store
    self.connectionState = connectionState
    self.isBusy = isBusy
  }

  var body: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      ToolbarCenterpieceView(
        model: model,
        displayMode: displayMode,
        availableDetailWidth: availableDetailWidth,
        statusMessages: statusMessages,
        daemonIndicator: daemonIndicator,
        store: store,
        connectionState: connectionState,
        isBusy: isBusy
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

  private static let standardDetailThreshold: CGFloat = 1_050
  private static let compactDetailThreshold: CGFloat = 960

  static func forDetailWidth(_ detailWidth: CGFloat) -> Self {
    switch detailWidth {
    case Self.standardDetailThreshold...:
      .standard
    case Self.compactDetailThreshold...:
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

  var showsMetricLabels: Bool { false }

  var principalHorizontalOffset: CGFloat {
    switch self {
    case .standard, .compact:
      0
    case .compressed:
      4
    }
  }

  func centerpieceWidth(for detailWidth: CGFloat) -> CGFloat {
    let ratio: CGFloat =
      switch self {
      case .standard:
        0.44
      case .compact:
        0.42
      case .compressed:
        0.34
      }

    let minimumWidth: CGFloat =
      switch self {
      case .standard:
        420
      case .compact:
        340
      case .compressed:
        208
      }

    let maximumWidth: CGFloat =
      switch self {
      case .standard:
        560
      case .compact:
        500
      case .compressed:
        300
      }

    return min(max(detailWidth * ratio, minimumWidth), maximumWidth)
  }

  func statusDropdownWidth(for detailWidth: CGFloat) -> CGFloat {
    let centerpieceWidth = centerpieceWidth(for: detailWidth)
    let minimumWidth: CGFloat =
      switch self {
      case .standard:
        210
      case .compact:
        175
      case .compressed:
        120
      }
    let maximumWidth: CGFloat =
      switch self {
      case .standard:
        260
      case .compact:
        220
      case .compressed:
        145
      }

    return min(max(centerpieceWidth * 0.44, minimumWidth), maximumWidth)
  }
}

struct ToolbarCenterpieceView: View {
  let model: ToolbarCenterpieceModel
  let displayMode: ToolbarCenterpieceDisplayMode
  let availableDetailWidth: CGFloat
  var statusMessages: [ToolbarStatusMessage] = []
  var daemonIndicator: ToolbarDaemonIndicator = .offline
  var store: HarnessMonitorStore?
  var connectionState: HarnessMonitorStore.ConnectionState = .idle
  var isBusy: Bool = false
  private static let toolbarHeight: CGFloat = 32
  // Leading inset matches the vertical centering gap inside the glass capsule
  // so the first metric token sits at equal distance from the bubble's inner
  // surface on all sides.
  private static let metricsLeadingInset: CGFloat = 12
  private static let daemonTrailingInset: CGFloat = 4

  init(
    model: ToolbarCenterpieceModel,
    displayMode: ToolbarCenterpieceDisplayMode,
    availableDetailWidth: CGFloat = 1_024,
    statusMessages: [ToolbarStatusMessage] = [],
    daemonIndicator: ToolbarDaemonIndicator = .offline,
    store: HarnessMonitorStore? = nil,
    connectionState: HarnessMonitorStore.ConnectionState = .idle,
    isBusy: Bool = false
  ) {
    self.model = model
    self.displayMode = displayMode
    self.availableDetailWidth = availableDetailWidth
    self.statusMessages = statusMessages
    self.daemonIndicator = daemonIndicator
    self.store = store
    self.connectionState = connectionState
    self.isBusy = isBusy
  }

  var body: some View {
    ZStack {
      Color.clear
        .accessibilityFrameMarker(HarnessMonitorAccessibility.toolbarCenterpieceFrame)

      HStack(spacing: 0) {
        ToolbarCenterpieceMetricsRow(metrics: model.metrics, displayMode: displayMode)
          .fixedSize(horizontal: true, vertical: false)
          .accessibilityFrameMarker(HarnessMonitorAccessibility.toolbarCenterpieceMetricsFrame)

        Spacer(minLength: 0)

        if !statusMessages.isEmpty {
          ToolbarStatusTickerCapsule(
            messages: statusMessages
          ) {
            daemonAccessory
          }
          .frame(width: displayMode.statusDropdownWidth(for: availableDetailWidth))
          .accessibilityFrameMarker(HarnessMonitorAccessibility.toolbarStatusTickerFrame)
        } else {
          daemonAccessory
        }
      }
      .padding(.leading, Self.metricsLeadingInset)
      .padding(.trailing, Self.daemonTrailingInset)
    }
    .frame(
      width: displayMode.centerpieceWidth(for: availableDetailWidth),
      height: Self.toolbarHeight
    )
    .offset(x: displayMode.principalHorizontalOffset)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.toolbarCenterpiece)
    .accessibilityLabel(model.accessibilityLabel)
    .accessibilityValue(model.accessibilityValue)
    .help("Live harness summary")
  }

  @ViewBuilder
  private var daemonAccessory: some View {
    HStack(spacing: 6) {
      ToolbarDaemonIndicatorIcon(indicator: daemonIndicator)
      if let store {
        ToolbarDaemonToggleControl(
          store: store,
          connectionState: connectionState,
          isBusy: isBusy
        )
      }
    }
  }
}
