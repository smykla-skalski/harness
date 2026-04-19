import HarnessMonitorKit
import SwiftUI

struct ContentCenterpieceToolbar: ToolbarContent {
  let model: ToolbarCenterpieceModel
  let displayMode: ToolbarCenterpieceDisplayMode
  let availableDetailWidth: CGFloat
  var statusMessages: [ToolbarStatusMessage] = []
  var connectionState: HarnessMonitorStore.ConnectionState = .idle

  init(
    model: ToolbarCenterpieceModel = .preview,
    displayMode: ToolbarCenterpieceDisplayMode = .standard,
    availableDetailWidth: CGFloat = 1_024,
    statusMessages: [ToolbarStatusMessage] = [],
    connectionState: HarnessMonitorStore.ConnectionState = .idle
  ) {
    self.model = model
    self.displayMode = displayMode
    self.availableDetailWidth = availableDetailWidth
    self.statusMessages = statusMessages
    self.connectionState = connectionState
  }

  var body: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      ToolbarCenterpieceView(
        model: model,
        displayMode: displayMode,
        availableDetailWidth: availableDetailWidth,
        statusMessages: statusMessages,
        connectionState: connectionState
      )
    }
  }
}

struct ToolbarCenterpieceModel: Equatable {
  let workspaceName: String
  let destinationName: String
  let destinationSystemImage: String

  static let preview = Self(
    workspaceName: "Harness Monitor",
    destinationName: "My Mac",
    destinationSystemImage: "laptopcomputer"
  )

  var accessibilityLabel: String {
    "\(workspaceName), \(destinationName)"
  }
}

public enum ToolbarCenterpieceDisplayMode: String {
  case standard
  case compact
  case compressed

  private static let standardDetailThreshold: CGFloat = 1_050
  private static let compactDetailThreshold: CGFloat = 960
  private static let thresholdHysteresis: CGFloat = 32

  public static func forDetailWidth(_ detailWidth: CGFloat) -> Self {
    switch detailWidth {
    case Self.standardDetailThreshold...:
      .standard
    case Self.compactDetailThreshold...:
      .compact
    default:
      .compressed
    }
  }

  public static func resolve(current: Self?, detailWidth: CGFloat) -> Self {
    guard let current else {
      return forDetailWidth(detailWidth)
    }
    return resolve(current: current, detailWidth: detailWidth)
  }

  public static func resolve(current: Self, detailWidth: CGFloat) -> Self {
    switch current {
    case .standard:
      if detailWidth < standardDetailThreshold - thresholdHysteresis {
        return .compact
      }
      return .standard
    case .compact:
      if detailWidth >= standardDetailThreshold + thresholdHysteresis {
        return .standard
      }
      if detailWidth < compactDetailThreshold - thresholdHysteresis {
        return .compressed
      }
      return .compact
    case .compressed:
      if detailWidth >= compactDetailThreshold + thresholdHysteresis {
        return .compact
      }
      return .compressed
    }
  }

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
  var connectionState: HarnessMonitorStore.ConnectionState = .idle
  @ScaledMetric(relativeTo: .body)
  private var daemonStatusDotSize: CGFloat = 20
  private static let toolbarHeight: CGFloat = 32
  private static let statusLeadingInset: CGFloat = 12
  private static let daemonTrailingInset: CGFloat = 10

  init(
    model: ToolbarCenterpieceModel,
    displayMode: ToolbarCenterpieceDisplayMode,
    availableDetailWidth: CGFloat = 1_024,
    statusMessages: [ToolbarStatusMessage] = [],
    connectionState: HarnessMonitorStore.ConnectionState = .idle
  ) {
    self.model = model
    self.displayMode = displayMode
    self.availableDetailWidth = availableDetailWidth
    self.statusMessages = statusMessages
    self.connectionState = connectionState
  }

  var body: some View {
    ZStack {
      Color.clear
        .accessibilityFrameMarker(HarnessMonitorAccessibility.toolbarCenterpieceFrame)

      HStack(spacing: 0) {
        Spacer(minLength: 0)

        if !statusMessages.isEmpty {
          ToolbarStatusTickerCapsule(
            messages: statusMessages
          ) {
            EmptyView()
          }
          .frame(width: displayMode.statusDropdownWidth(for: availableDetailWidth))
          .accessibilityFrameMarker(HarnessMonitorAccessibility.toolbarStatusTickerFrame)
        }

        daemonStatusDot
      }
      .padding(.leading, Self.statusLeadingInset)
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
    .help("Live harness summary")
  }

  private var daemonStatusDot: some View {
    ToolbarDaemonStatusDot(connectionState: connectionState)
      .frame(width: daemonStatusDotSize, height: daemonStatusDotSize)
  }
}
