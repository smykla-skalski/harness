import HarnessMonitorKit
import SwiftUI

private final class ToolbarCenterpieceBundleToken {}

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
  private static let compactDetailThreshold: CGFloat = 820

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

  func centerpieceWidth(for detailWidth: CGFloat) -> CGFloat {
    let ratio: CGFloat =
      switch self {
      case .standard:
        0.44
      case .compact:
        0.42
      case .compressed:
        0.4
      }

    let minimumWidth: CGFloat =
      switch self {
      case .standard:
        420
      case .compact:
        340
      case .compressed:
        260
      }

    let maximumWidth: CGFloat =
      switch self {
      case .standard:
        560
      case .compact:
        500
      case .compressed:
        380
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
        140
      }
    let maximumWidth: CGFloat =
      switch self {
      case .standard:
        260
      case .compact:
        220
      case .compressed:
        180
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
  private static let metricsLeadingInset: CGFloat = 16
  private static let daemonTrailingInset: CGFloat = 8

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
          ToolbarStatusDropdown(
            messages: statusMessages
          )
          .frame(width: displayMode.statusDropdownWidth(for: availableDetailWidth))
          .accessibilityFrameMarker(HarnessMonitorAccessibility.toolbarStatusTickerFrame)
        }

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
      .padding(.leading, Self.metricsLeadingInset)
      .padding(.trailing, Self.daemonTrailingInset)
    }
    .frame(
      width: displayMode.centerpieceWidth(for: availableDetailWidth),
      height: Self.toolbarHeight
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.toolbarCenterpiece)
    .accessibilityLabel(model.accessibilityLabel)
    .accessibilityValue(model.accessibilityValue)
    .help("Live harness summary")
  }
}

private let centerpieceBundleRef = Bundle(for: ToolbarCenterpieceBundleToken.self)

private struct ToolbarDaemonIndicatorIcon: View {
  let indicator: ToolbarDaemonIndicator
  private static let containerWidth: CGFloat = 16

  var body: some View {
    Group {
      switch indicator {
      case .offline:
        Circle()
          .fill(Color.secondary.opacity(0.5))
          .frame(width: 8, height: 8)
      case .launchdConnected:
        Image("LaunchDaemonRocket", bundle: centerpieceBundleRef)
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
          .frame(height: 14)
      case .manualConnected:
        Image(systemName: "person.fill")
          .font(.caption.weight(.semibold))
      }
    }
    .frame(width: Self.containerWidth, alignment: .trailing)
    .foregroundStyle(indicator.foregroundColor)
    .animation(nil, value: indicator)
    .accessibilityHidden(true)
  }
}

private struct ToolbarDaemonToggleControl: View {
  let store: HarnessMonitorStore
  let connectionState: HarnessMonitorStore.ConnectionState
  let isBusy: Bool
  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  var body: some View {
    Button {
      guard !isLoading else { return }
      Task {
        if isDaemonOnline {
          await store.stopDaemon()
        } else {
          await store.startDaemon()
        }
      }
    } label: {
      ZStack {
        dotLayer
        powerLayer
      }
      .frame(width: 20, height: 20)
      .opacity(isLoading ? 0.7 : 1)
      .contentShape(Circle())
    }
    .buttonStyle(ToolbarDaemonPowerToggleButtonStyle(reduceMotion: reduceMotion))
    .contentShape(Rectangle())
    .onContinuousHover { phase in
      let hovered: Bool
      switch phase {
      case .active:
        hovered = true
      case .ended:
        hovered = false
      }
      guard hovered != isHovered else { return }
      withAnimation(morphAnimation) {
        isHovered = hovered
      }
    }
    .help(isDaemonOnline ? "Stop daemon" : "Start daemon")
    .accessibilityLabel(isDaemonOnline ? "Stop Daemon" : "Start Daemon")
    .accessibilityValue(statusTitle)
    .accessibilityIdentifier(HarnessMonitorAccessibility.toolbarStartDaemonButton)
  }

  private var isDaemonOnline: Bool {
    connectionState == .online
  }

  private var isLoading: Bool {
    isBusy || connectionState == .connecting
  }

  private var statusTitle: String {
    switch connectionState {
    case .online: "Online"
    case .connecting: "Connecting"
    case .idle: "Idle"
    case .offline: "Offline"
    }
  }

  private var statusColor: Color {
    switch connectionState {
    case .online: HarnessMonitorTheme.success
    case .connecting: HarnessMonitorTheme.caution
    case .idle: HarnessMonitorTheme.accent
    case .offline: HarnessMonitorTheme.danger
    }
  }

  private var fillOpacity: Double {
    if reduceTransparency {
      return colorSchemeContrast == .increased ? 0.88 : 0.8
    }
    return colorSchemeContrast == .increased ? 0.76 : 0.66
  }

  private var strokeOpacity: Double {
    colorSchemeContrast == .increased ? 0.92 : 0.72
  }

  private var dotLayer: some View {
    Circle()
      .fill(statusColor.opacity(fillOpacity))
      .frame(width: 10, height: 10)
      .background {
        Circle()
          .strokeBorder(statusColor.opacity(strokeOpacity), lineWidth: 1)
      }
      .opacity(1 - morphProgress)
      .scaleEffect(1 + (0.7 * morphProgress))
      .blur(radius: 2 * morphProgress)
  }

  private var powerLayer: some View {
    Image(systemName: "power")
      .font(.system(.body, weight: .semibold))
      .foregroundStyle(iconColor)
      .opacity(morphProgress)
      .scaleEffect(0.25 + (0.75 * morphProgress))
      .rotationEffect(.degrees(powerRotationDegrees))
  }

  private var iconColor: Color {
    if isLoading { return HarnessMonitorTheme.secondaryInk }
    return isDaemonOnline ? HarnessMonitorTheme.danger : HarnessMonitorTheme.success
  }

  private var morphAnimation: Animation? {
    if reduceMotion {
      return .easeOut(duration: 0.12)
    }
    return .interactiveSpring(response: 0.42, dampingFraction: 0.78, blendDuration: 0.18)
  }

  private var morphProgress: CGFloat {
    isHovered ? 1 : 0
  }

  private var powerRotationDegrees: Double {
    Double(-95 + (95 * morphProgress))
  }
}

private struct ToolbarDaemonPowerToggleButtonStyle: ButtonStyle {
  let reduceMotion: Bool

  func makeBody(configuration: Configuration) -> some View {
    let isPressed = configuration.isPressed

    configuration.label
      .scaleEffect(isPressed ? 0.9 : 1)
      .offset(y: isPressed ? 0.35 : 0)
      .brightness(isPressed ? -0.03 : 0)
      .saturation(isPressed ? 0.96 : 1)
      .animation(pressAnimation, value: configuration.isPressed)
  }

  private var pressAnimation: Animation? {
    if reduceMotion {
      return .easeOut(duration: 0.08)
    }
    return .interactiveSpring(response: 0.18, dampingFraction: 0.45, blendDuration: 0.14)
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
