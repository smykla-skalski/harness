import HarnessMonitorKit
import SwiftUI

struct SessionTimelineCards: View {
  let nodes: [SessionTimelineNode]
  let placeholderCount: Int
  let shimmerPhase: CGFloat
  let showsShimmer: Bool
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let actionHandler: any DecisionActionHandler

  var body: some View {
    LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      ForEach(nodes) { node in
        SessionTimelineNodeRow(
          node: node,
          dateTimeConfiguration: dateTimeConfiguration,
          actionHandler: actionHandler
        )
      }

      ForEach(Array(0..<placeholderCount), id: \.self) { index in
        SessionCockpitTimelinePlaceholderRow(
          seed: index,
          shimmerPhase: shimmerPhase,
          showsShimmer: showsShimmer
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(alignment: .topLeading) {
      if !nodes.isEmpty || placeholderCount > 0 {
        SessionTimelineRailBackground()
      }
    }
  }
}

private struct SessionTimelineNodeRow: View {
  let node: SessionTimelineNode
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let actionHandler: any DecisionActionHandler

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.itemSpacing) {
      Text(timestampText)
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(2)
        .multilineTextAlignment(.trailing)
        .frame(width: SessionTimelineLayout.timeColumnWidth, alignment: .trailing)

      SessionTimelineDot(tint: cardTint)

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        cardContent
        SessionTimelineActionButtons(actions: node.actions, handler: actionHandler)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, HarnessMonitorTheme.cardPadding)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .background(SessionTimelineCardBackground(tint: cardTint))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contextMenu {
      Button {
        HarnessMonitorClipboard.copy(node.title)
      } label: {
        Label("Copy Summary", systemImage: "doc.on.doc")
      }
    }
  }

  private var cardContent: some View {
    ViewThatFits(in: .horizontal) {
      wideContent
      compactContent
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier(node.accessibilityIdentifier)
  }

  private var wideContent: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
          kindBadge
          Text(node.title)
            .scaledFont(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(HarnessMonitorTheme.ink)
            .lineLimit(1)
          Text(node.sourceLabel)
            .scaledFont(.callout.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
        }
        if let detail = node.detail {
          Text(detail)
            .scaledFont(.callout)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      rightBadges
    }
  }

  private var compactContent: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
        kindBadge
        Text(node.sourceLabel)
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        rightBadges
      }

      Text(node.title)
        .scaledFont(.system(.body, design: .rounded, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)

      if let detail = node.detail {
        Text(detail)
          .scaledFont(.callout)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(2)
      }
    }
  }

  private var kindBadge: some View {
    SessionTimelineBadge(label: node.kind.label, tint: typeTint, style: .quiet)
  }

  private var rightBadges: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
      ForEach(statusBadges) { badge in
        SessionTimelineBadge(label: badge.label, tint: badge.tint, style: .prominent)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var timestampText: String {
    if let rawTimestamp = node.rawTimestamp {
      return formatTimelineTimestamp(rawTimestamp, configuration: dateTimeConfiguration)
    }
    return formatTimelineTimestamp(node.timestamp, configuration: dateTimeConfiguration)
  }

  private var accessibilityLabel: String {
    var parts = [
      node.kind.label,
      timestampText,
      "Source \(node.sourceLabel)",
    ]
    if let eventTone = node.eventTone {
      parts.append("Tone \(eventTone.label)")
    }
    if let decision = node.decision {
      parts.append("Severity \(decision.severityLabel)")
    }
    parts.append(node.title)
    if let detail = node.detail {
      parts.append(detail)
    }
    parts.append(node.actionAvailabilityLabel)
    return parts.joined(separator: ", ")
  }

  private var typeTint: Color {
    switch node.kind {
    case .event:
      cardTint
    case .decision:
      HarnessMonitorTheme.accent
    case .linkedDecision:
      HarnessMonitorTheme.caution
    }
  }

  private var cardTint: Color {
    if let eventTone = node.eventTone {
      return eventTone.color
    }
    return node.decision?.severity.color ?? HarnessMonitorTheme.secondaryInk
  }

  private var statusBadges: [SessionTimelineStatusBadge] {
    var badges: [SessionTimelineStatusBadge] = []
    if let eventTone = node.eventTone {
      badges.append(SessionTimelineStatusBadge(label: eventTone.badgeLabel, tint: eventTone.color))
    }
    if let decision = node.decision {
      badges.append(
        SessionTimelineStatusBadge(
          label: decision.severity.badgeLabel,
          tint: decision.severity.color
        )
      )
    }
    return badges
  }
}

enum SessionTimelineLayout {
  static let timeColumnWidth: CGFloat = 92
  static let railWidth: CGFloat = 14
  static let railLineOffset =
    timeColumnWidth + HarnessMonitorTheme.itemSpacing + (railWidth / 2)
}

private struct SessionTimelineRailBackground: View {
  var body: some View {
    GeometryReader { proxy in
      Rectangle()
        .fill(HarnessMonitorTheme.controlBorder.opacity(0.55))
        .frame(width: 2, height: max(0, proxy.size.height - HarnessMonitorTheme.spacingLG))
        .offset(
          x: SessionTimelineLayout.railLineOffset - 1,
          y: HarnessMonitorTheme.spacingSM
        )
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

private struct SessionTimelineDot: View {
  let tint: Color

  var body: some View {
    Circle()
      .fill(tint)
      .frame(width: 11, height: 11)
      .frame(width: SessionTimelineLayout.railWidth, alignment: .center)
      .padding(.top, 6)
      .shadow(color: tint.opacity(0.4), radius: 8)
      .background {
        Circle()
          .fill(.background)
          .frame(width: 19, height: 19)
      }
      .accessibilityHidden(true)
  }
}

private struct SessionTimelineCardBackground: View {
  let tint: Color

  var body: some View {
    RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
      .fill(tint.opacity(0.08))
      .overlay {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
          .stroke(tint.opacity(0.35), lineWidth: 1)
      }
  }
}

private struct SessionTimelineBadge: View {
  enum Style {
    case quiet
    case prominent
  }

  let label: String
  let tint: Color
  let style: Style

  var body: some View {
    Text(label)
      .scaledFont(.caption2.weight(.semibold))
      .lineLimit(1)
      .padding(.horizontal, HarnessMonitorTheme.spacingXS)
      .padding(.vertical, 3)
      .background {
        Capsule(style: .continuous)
          .fill(backgroundTint)
      }
      .foregroundStyle(tint)
  }

  private var backgroundTint: Color {
    switch style {
    case .quiet:
      tint.opacity(0.11)
    case .prominent:
      tint.opacity(0.20)
    }
  }
}

private struct SessionTimelineStatusBadge: Identifiable {
  let label: String
  let tint: Color

  var id: String { label }
}

extension SessionTimelineTone {
  fileprivate var color: Color {
    switch self {
    case .info:
      HarnessMonitorTheme.accent
    case .success:
      HarnessMonitorTheme.success
    case .warning:
      HarnessMonitorTheme.caution
    case .critical:
      HarnessMonitorTheme.danger
    }
  }

  fileprivate var badgeLabel: String {
    switch self {
    case .info:
      "INFO"
    case .success:
      "SUCCESS"
    case .warning:
      "WARN"
    case .critical:
      "DANGER"
    }
  }
}

extension DecisionSeverity {
  fileprivate var color: Color {
    switch self {
    case .info:
      HarnessMonitorTheme.accent
    case .warn:
      HarnessMonitorTheme.caution
    case .needsUser:
      HarnessMonitorTheme.accent
    case .critical:
      HarnessMonitorTheme.danger
    }
  }

  fileprivate var badgeLabel: String {
    switch self {
    case .info:
      "INFO"
    case .warn:
      "WARN"
    case .needsUser:
      "NEEDS USER"
    case .critical:
      "DANGER"
    }
  }
}
