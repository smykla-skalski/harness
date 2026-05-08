import HarnessMonitorKit
import SwiftUI

struct SessionSidebarRow: View {
  let title: String
  let systemImage: String
  let severityShape: SessionSidebarSeverityShape
  let severityTint: Color
  var showsDragHandle = false
  var isDropTargeted = false
  var isMultiSelect = false
  var isSelected = false
  var toggleSelection: (() -> Void)?
  @Environment(\.fontScale)
  private var fontScale
  @State private var isHovering = false

  private var metrics: SessionSidebarRowMetrics {
    SessionSidebarRowMetrics(fontScale: fontScale)
  }

  var body: some View {
    HStack(spacing: metrics.spacing) {
      if isMultiSelect {
        Button {
          toggleSelection?()
        } label: {
          Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .imageScale(.small)
            .scaledFont(.body)
        }
        .buttonStyle(.borderless)
        .frame(
          width: metrics.multiSelectControlSize,
          height: metrics.multiSelectControlSize
        )
        .contentShape(Rectangle())
        .accessibilityLabel(isSelected ? "Deselect \(title)" : "Select \(title)")
      }

      Image(systemName: showsDragHandle && isHovering ? "line.3.horizontal" : systemImage)
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

      Text(title)
        .scaledFont(.body)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, minHeight: metrics.minHeight, alignment: .leading)
    .padding(.vertical, metrics.verticalPadding)
    .padding(.horizontal, isDropTargeted ? 4 : 0)
    .background {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: metrics.dropCornerRadius)
          .strokeBorder(.tint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
      }
    }
    .onHover { isHovering = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
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

struct SessionSidebarRowMetrics: Equatable {
  let spacing: CGFloat
  let minHeight: CGFloat
  let verticalPadding: CGFloat
  let iconColumnWidth: CGFloat
  let multiSelectControlSize: CGFloat
  let severityIndicatorSize: CGFloat
  let severityIndicatorOffset: CGFloat
  let severityAlertFontSize: CGFloat
  let dropCornerRadius: CGFloat

  init(fontScale: CGFloat) {
    let scale = min(max(fontScale, 0.85), 1.8)
    spacing = 8
    minHeight = max(28, 26 * scale)
    verticalPadding = max(1, 1.5 * min(scale, 1.4))
    iconColumnWidth = max(16, 16 * min(scale, 1.35))
    multiSelectControlSize = scale >= 1.45 ? 44 : max(24, 22 * scale)
    severityIndicatorSize = max(8, 8 * min(scale, 1.5))
    severityIndicatorOffset = max(4, 4 * min(scale, 1.35))
    severityAlertFontSize = max(6, 6 * min(scale, 1.5))
    dropCornerRadius = max(5, 5 * min(scale, 1.25))
  }
}

public enum SessionSidebarSeverityShape: Hashable, Sendable {
  case none
  case dot
  case ring
  case alert
}
