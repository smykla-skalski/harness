import Foundation
import HarnessMonitorKit
import Observation
import SwiftUI

struct TaskBoardLaneMetrics: Equatable {
  let laneSpacing: CGFloat
  let laneInnerPadding: CGFloat
  let listRowHorizontalInset: CGFloat
  let laneWidth: CGFloat
  let laneCollapsedWidth: CGFloat
  let laneCollapsedInnerPadding: CGFloat
  let laneCollapsedBadgeSize: CGFloat
  let laneCollapsedTextWidth: CGFloat
  let laneCollapsedTitleHeight: CGFloat
  let laneCollapsedContentTopPadding: CGFloat
  let laneFixedHeight: CGFloat
  let laneBodyTopPadding: CGFloat
  let laneAccentHeight: CGFloat
  let laneAccentVisibleHeight: CGFloat
  let laneAccentCornerRadius: CGFloat
  let laneAccentInteriorCornerRadius: CGFloat
  let headerIconWidth: CGFloat
  let headerBottomPadding: CGFloat
  let laneHeaderBodyTopPadding: CGFloat
  let countHorizontalPadding: CGFloat
  let countVerticalPadding: CGFloat
  let emptyLaneMinHeight: CGFloat
  let cardPadding: CGFloat
  let cardCornerRadius: CGFloat
  let cardMarkerSize: CGFloat
  let cardMarkerTopPadding: CGFloat
  let rowTextSpacing: CGFloat
  let pillHorizontalPadding: CGFloat
  let pillVerticalPadding: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    let denseScale = min(scale, 1.3)
    let broadScale = min(scale, 1.16)
    let heightScale = min(scale, 1.18)
    laneSpacing = HarnessMonitorTheme.spacingSM * denseScale
    laneInnerPadding = HarnessMonitorTheme.spacingMD * denseScale
    // A macOS plain List reserves spacingSM outside listRowInsets, and
    // listSectionMargins is unavailable on macOS. Keep the remaining inset here
    // so the card edge still lands on the header's laneInnerPadding.
    listRowHorizontalInset = max(0, laneInnerPadding - HarnessMonitorTheme.spacingSM)
    laneWidth = 420 * broadScale
    laneCollapsedWidth = max(72, 72 * min(scale, 1.12))
    laneCollapsedInnerPadding = HarnessMonitorTheme.spacingSM * denseScale
    laneCollapsedBadgeSize = max(34, 34 * min(scale, 1.18))
    laneCollapsedTextWidth = max(28, 28 * min(scale, 1.18))
    laneCollapsedTitleHeight = max(160, 160 * min(scale, 1.18))
    laneCollapsedContentTopPadding = HarnessMonitorTheme.spacingMD * denseScale
    laneFixedHeight = 704 * heightScale
    laneBodyTopPadding = HarnessMonitorTheme.spacingSM * denseScale
    laneAccentHeight = max(8, 8 * min(scale, 1.12))
    laneAccentVisibleHeight = max(4, 4 * min(scale, 1.12))
    headerIconWidth = 18 * min(scale, 1.25)
    headerBottomPadding = HarnessMonitorTheme.spacingSM * denseScale
    laneHeaderBodyTopPadding = max(0, laneInnerPadding - headerBottomPadding)
    countHorizontalPadding = HarnessMonitorTheme.spacingSM * denseScale
    countVerticalPadding = HarnessMonitorTheme.spacingXS * min(scale, 1.2)
    emptyLaneMinHeight = 92 * heightScale
    cardPadding = HarnessMonitorTheme.spacingMD * denseScale
    cardCornerRadius = HarnessMonitorTheme.cornerRadiusSM
    laneAccentCornerRadius = min(cardCornerRadius, laneAccentHeight)
    laneAccentInteriorCornerRadius = min(cardCornerRadius, laneAccentHeight)
    cardMarkerSize = 28 * min(scale, 1.15)
    cardMarkerTopPadding = 2 * denseScale
    rowTextSpacing = HarnessMonitorTheme.spacingXS * denseScale
    pillHorizontalPadding = HarnessMonitorTheme.pillPaddingH * denseScale
    pillVerticalPadding = HarnessMonitorTheme.pillPaddingV * min(scale, 1.2)
  }
}

struct TaskBoardEmptyLane: View {
  let lane: TaskBoardInboxLane
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.taskBoardLaneAppearance)
  private var laneAppearance

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(spacing: metrics.laneSpacing) {
      if let symbolName = taskBoardLaneSystemImage(for: lane, appearance: laneAppearance) {
        TaskBoardCardLeadingIcon(
          systemImage: symbolName,
          tint: taskBoardLaneColor(for: lane, appearance: laneAppearance)
        )
      }
      Text("Nothing here")
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, minHeight: metrics.emptyLaneMinHeight)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(lane.title) lane empty")
  }
}

struct TaskBoardCardLeadingIcon: View {
  let systemImage: String
  let tint: Color
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var iconFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    Image(systemName: systemImage)
      .font(iconFont)
      .foregroundStyle(tint)
      .frame(width: metrics.cardMarkerSize, height: metrics.cardMarkerSize)
      .background(tint.opacity(0.16), in: Circle())
      .accessibilityHidden(true)
  }
}

struct TaskBoardCardTitleTypography {
  let font: Font
  let codeFont: Font

  init(fontScale: CGFloat) {
    font = HarnessMonitorTextSize.scaledFont(
      .subheadline.weight(.semibold),
      by: fontScale
    )
    codeFont = HarnessMonitorTextSize.scaledFont(
      .subheadline.monospaced().weight(.semibold),
      by: fontScale
    )
  }
}

struct TaskBoardCardFooter<Badges: View>: View {
  let repository: String
  let projectMark: TaskBoardProjectMarkStyle?
  let updatedAt: Date?
  let badges: Badges
  @Environment(\.fontScale)
  private var fontScale

  init(
    repository: String,
    projectMark: TaskBoardProjectMarkStyle? = nil,
    updatedAt: Date?,
    @ViewBuilder badges: () -> Badges
  ) {
    self.repository = repository
    self.projectMark = projectMark
    self.updatedAt = updatedAt
    self.badges = badges()
  }

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var repositoryFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }
  private var updatedAtFont: Font {
    HarnessMonitorTextSize.scaledFont(.system(size: 8), by: fontScale)
  }

  var body: some View {
    HStack(alignment: .center, spacing: metrics.rowTextSpacing) {
      // The mark and the name are one unit: the color is a faster way to spot
      // a project you already know, never the only way to tell which it is.
      // They align on the name's baseline, not on two centre guides that do not
      // agree, and the pair then meets the rest of the row optically centred.
      HStack(alignment: .firstTextBaseline, spacing: metrics.rowTextSpacing) {
        if let projectMark {
          TaskBoardProjectMark(style: projectMark, alignsWith: .caption1)
        }
        Text(repository)
          .font(repositoryFont)
          .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
          .lineLimit(1)
          .truncationMode(.middle)
          .multilineTextAlignment(.leading)
      }
      .harnessOpticalTextCenter()
      .layoutPriority(2)
      HarnessMonitorWrapLayout(
        spacing: metrics.rowTextSpacing,
        lineSpacing: metrics.rowTextSpacing
      ) {
        badges
      }
      .environment(\.taskBoardCardPillDensity, .compact)
      .frame(maxWidth: .infinity, alignment: .leading)
      .layoutPriority(1)
      TaskBoardCardUpdatedAtLabel(updatedAt: updatedAt, font: updatedAtFont)
        .layoutPriority(3)
    }
  }
}

@MainActor
@Observable
final class TaskBoardRelativeTimeClock {
  private(set) var referenceDate: Date

  init(referenceDate: Date = .now) {
    self.referenceDate = referenceDate
  }

  func refresh(at referenceDate: Date = .now) {
    guard self.referenceDate != referenceDate else { return }
    self.referenceDate = referenceDate
  }

  func run() async {
    refresh()
    while await Self.sleepUntilNextUpdate() {
      refresh()
    }
  }

  private static func sleepUntilNextUpdate() async -> Bool {
    do {
      try await Task.sleep(for: .seconds(60))
      return !Task.isCancelled
    } catch {
      return false
    }
  }
}

enum TaskBoardLaneRevealAnchor: Equatable, Sendable {
  case top
  case minimal
  case bottom
}

struct TaskBoardLaneRevealRequest: Equatable, Sendable {
  let generation: UInt64
  let retryAttempt: Int
  let cardID: TaskBoardCardID
  let lane: TaskBoardInboxLane
  let anchor: TaskBoardLaneRevealAnchor
  let priorDestinationCardIDs: [TaskBoardCardID]
}

@MainActor
@Observable
final class TaskBoardLaneRevealCoordinator {
  private static let maximumRetryAttempts = 2
  private var generation: UInt64 = 0
  private(set) var pendingRequest: TaskBoardLaneRevealRequest?

  @discardableResult
  func request(
    cardID: TaskBoardCardID,
    in lane: TaskBoardInboxLane,
    anchor: TaskBoardLaneRevealAnchor,
    priorDestinationCardIDs: [TaskBoardCardID]
  ) -> TaskBoardLaneRevealRequest {
    generation &+= 1
    let request = TaskBoardLaneRevealRequest(
      generation: generation,
      retryAttempt: 0,
      cardID: cardID,
      lane: lane,
      anchor: anchor,
      priorDestinationCardIDs: priorDestinationCardIDs
    )
    pendingRequest = request
    return request
  }

  func actionableRequest(
    in lane: TaskBoardInboxLane,
    orderedCardIDs: [TaskBoardCardID]
  ) -> TaskBoardLaneRevealRequest? {
    guard
      let request = pendingRequest,
      request.lane == lane,
      orderedCardIDs.contains(request.cardID),
      orderedCardIDs != request.priorDestinationCardIDs
    else {
      return nil
    }
    return request
  }

  func isPending(_ request: TaskBoardLaneRevealRequest) -> Bool {
    pendingRequest?.generation == request.generation
  }

  /// Reissues the current logical request with a fresh identity. A native list
  /// reveal can be attempted before AppKit has installed or laid out its table;
  /// changing the generation lets the lane's task retry after that layout turn
  /// without allowing an older reveal to replace a newer user action.
  @discardableResult
  func retry(
    _ request: TaskBoardLaneRevealRequest
  ) -> TaskBoardLaneRevealRequest? {
    guard
      isPending(request),
      request.retryAttempt < Self.maximumRetryAttempts
    else {
      return nil
    }
    generation &+= 1
    let retryRequest = TaskBoardLaneRevealRequest(
      generation: generation,
      retryAttempt: request.retryAttempt + 1,
      cardID: request.cardID,
      lane: request.lane,
      anchor: request.anchor,
      priorDestinationCardIDs: request.priorDestinationCardIDs
    )
    pendingRequest = retryRequest
    return retryRequest
  }

  func consume(_ request: TaskBoardLaneRevealRequest) {
    guard isPending(request) else { return }
    pendingRequest = nil
  }
}
