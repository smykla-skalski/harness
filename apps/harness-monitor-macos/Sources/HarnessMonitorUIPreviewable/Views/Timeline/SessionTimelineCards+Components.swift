import SwiftUI

enum SessionTimelineLayout {
  static let timeColumnWidth: CGFloat = 78
  static let railWidth: CGFloat = 14
  static let markerDiameter: CGFloat = 19
  static let markerCoreDiameter: CGFloat = 11
  static let railLineOffset =
    timeColumnWidth + HarnessMonitorTheme.itemSpacing + (railWidth / 2)
}

extension VerticalAlignment {
  enum SessionTimelineMarkerCenter: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
      context[VerticalAlignment.center]
    }
  }

  static let sessionTimelineMarkerCenter = VerticalAlignment(
    SessionTimelineMarkerCenter.self
  )

  enum SessionTimelineFirstLineCenter: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
      context[VerticalAlignment.center]
    }
  }

  static let sessionTimelineFirstLineCenter = VerticalAlignment(
    SessionTimelineFirstLineCenter.self
  )
}

struct SessionTimelineMarkerBoundsKey: PreferenceKey {
  static var defaultValue: Anchor<CGRect>? { nil }

  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = nextValue() ?? value
  }
}

struct SessionTimelineRailBackground: View {
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

struct SessionTimelineConnectorOverlay: View {
  let markerAnchor: Anchor<CGRect>?
  let showsConnectorAbove: Bool
  let showsConnectorBelow: Bool

  var body: some View {
    GeometryReader { proxy in
      if let markerAnchor, showsConnectorAbove || showsConnectorBelow {
        let rect = proxy[markerAnchor]
        let x = rect.midX
        let centerY = rect.midY
        Path { path in
          if showsConnectorAbove {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: centerY))
          }
          if showsConnectorBelow {
            path.move(to: CGPoint(x: x, y: centerY))
            path.addLine(to: CGPoint(x: x, y: proxy.size.height))
          }
        }
        .stroke(
          HarnessMonitorTheme.controlBorder.opacity(0.55),
          style: StrokeStyle(lineWidth: 2)
        )
      }
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

struct SessionTimelineDot: View {
  let tint: Color

  var body: some View {
    ZStack {
      Circle()
        .fill(.background)
        .frame(
          width: SessionTimelineLayout.markerDiameter,
          height: SessionTimelineLayout.markerDiameter
        )
      Circle()
        .fill(tint)
        .frame(
          width: SessionTimelineLayout.markerCoreDiameter,
          height: SessionTimelineLayout.markerCoreDiameter
        )
    }
    .frame(width: SessionTimelineLayout.railWidth, alignment: .center)
    .shadow(color: tint.opacity(0.4), radius: 8)
    .anchorPreference(key: SessionTimelineMarkerBoundsKey.self, value: .bounds) { $0 }
    .accessibilityHidden(true)
  }
}

struct SessionTimelineCardBackground: View {
  let tint: Color

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
  }

  var body: some View {
    shape
      .fill(tint.opacity(0.08))
      .overlay {
        shape
          .strokeBorder(tint.opacity(0.35), lineWidth: 1)
      }
  }
}
