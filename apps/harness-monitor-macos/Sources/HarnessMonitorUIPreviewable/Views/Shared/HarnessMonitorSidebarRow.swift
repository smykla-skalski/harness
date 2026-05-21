import HarnessMonitorKit
import SwiftUI

struct HarnessMonitorSidebarRow: View {
  let title: String
  var subtitle: String?
  let systemImage: String
  var severityShape: HarnessMonitorSidebarSeverityShape = .none
  var severityTint: Color = .gray
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: HarnessMonitorSidebarRowMetrics {
    HarnessMonitorSidebarRowMetrics(fontScale: fontScale)
  }

  var body: some View {
    HStack(spacing: metrics.spacing) {
      Image(systemName: systemImage)
        .scaledFont(.body)
        .foregroundStyle(.secondary)
        .frame(width: metrics.iconColumnWidth)
        .accessibilityHidden(true)
        .overlay(alignment: .topTrailing) {
          severityIndicator
            .frame(
              width: metrics.severityIndicatorSize,
              height: metrics.severityIndicatorSize
            )
            .offset(x: metrics.severityIndicatorOffset, y: -metrics.severityIndicatorOffset)
        }

      VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 1) {
        Text(title)
          .scaledFont(.body)
          .lineLimit(1)
        if let subtitle, subtitle.isEmpty == false {
          Text(subtitle)
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, metrics.verticalPadding)
    .frame(maxWidth: .infinity, minHeight: metrics.minHeight, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    if let subtitle, subtitle.isEmpty == false {
      return "\(title), \(subtitle)"
    }
    return title
  }

  @ViewBuilder private var severityIndicator: some View {
    switch severityShape {
    case .none:
      EmptyView()
    case .dot:
      Circle().fill(severityTint)
    case .ring:
      Circle().strokeBorder(severityTint, lineWidth: 1.5)
    case .alert:
      Image(systemName: "exclamationmark")
        .font(.system(size: metrics.severityAlertFontSize, weight: .heavy))
        .foregroundStyle(severityTint)
    }
  }
}

struct HarnessMonitorSidebarRowMetrics: Equatable {
  let spacing: CGFloat
  let minHeight: CGFloat
  let verticalPadding: CGFloat
  let iconColumnWidth: CGFloat
  let severityIndicatorSize: CGFloat
  let severityIndicatorOffset: CGFloat
  let severityAlertFontSize: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    spacing = 8
    minHeight = max(28, 26 * scale)
    verticalPadding = max(1, 1.5 * min(scale, 1.4))
    iconColumnWidth = max(16, 16 * min(scale, 1.35))
    severityIndicatorSize = max(8, 8 * min(scale, 1.5))
    severityIndicatorOffset = max(4, 4 * min(scale, 1.35))
    severityAlertFontSize = max(6, 6 * min(scale, 1.5))
  }
}

public enum HarnessMonitorSidebarSeverityShape: Hashable, Sendable {
  case none
  case dot
  case ring
  case alert
}

func harnessSidebarRowSize(for textSizeIndex: Int) -> SidebarRowSize {
  switch HarnessMonitorTextSize.normalizedIndex(textSizeIndex) {
  case ..<HarnessMonitorTextSize.defaultIndex:
    .small
  case HarnessMonitorTextSize.defaultIndex..<HarnessMonitorTextSize.scales.count - 1:
    .medium
  default:
    .large
  }
}
