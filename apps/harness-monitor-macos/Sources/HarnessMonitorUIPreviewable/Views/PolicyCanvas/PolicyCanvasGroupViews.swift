import SwiftUI

/// Layer of group regions rendered behind the nodes. Pulled out of
/// `PolicyCanvasWorkspaceViews.swift` so the workspace file stays under the
/// 420-line cap; Wave 4K added the acceptance-flash + thicker drop affordance
/// state to `PolicyCanvasGroupRegion`, which pushed the workspace file over
/// the limit.
struct PolicyCanvasGroupLayer: View {
  let viewModel: PolicyCanvasViewModel
  let focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding

  var body: some View {
    ForEach(viewModel.groups) { group in
      PolicyCanvasGroupRegion(
        group: group,
        isSelected: viewModel.isSelected(.group(group.id)),
        isHighlighted: viewModel.highlightedGroupID == group.id,
        isFlashing: viewModel.groupAcceptanceFlashID == group.id
      )
      .offset(x: group.frame.minX, y: group.frame.minY)
      .accessibilityFocused(focusedComponent, equals: .group(group.id))
      .gesture(
        DragGesture(minimumDistance: 3)
          .onChanged { value in
            viewModel.dragGroup(group.id, translation: value.translation)
          }
          .onEnded { value in
            viewModel.endGroupDrag(group.id, translation: value.translation)
          }
      )
      .simultaneousGesture(
        TapGesture()
          .modifiers(.shift)
          .onEnded {
            viewModel.extendSelection(.group(group.id))
          }
      )
      .onTapGesture {
        viewModel.select(.group(group.id))
      }
      .dropDestination(for: String.self) { payloads, _ in
        viewModel.dropPalettePayloadsOnGroup(
          payloads,
          groupID: group.id,
          at: CGPoint(x: group.frame.midX, y: group.frame.midY)
        )
      } isTargeted: { targeted in
        viewModel.setGroupDropTargeted(targeted, groupID: group.id)
      }
    }
  }
}

struct PolicyCanvasGroupRegion: View {
  let group: PolicyCanvasGroup
  let isSelected: Bool
  let isHighlighted: Bool
  /// Wave 4K P36 acceptance flash — true while a successful drop is fresh.
  /// View-only: the model state lives in `PolicyCanvasViewModel`'s observed
  /// `groupAcceptanceFlashID`. The reduce-motion gate is below in `body`.
  let isFlashing: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // Drag-over without drop: thicken the dashed stroke from 1.6→2.4pt and
    // saturate the fill from .16/.24 baseline. Acceptance flash piles on
    // top — extra fill opacity + a solid accent stroke that overlays the
    // dashed one. Both signals respect reduce-motion: with motion reduced,
    // we keep the static visual difference (thicker stroke, accent overlay)
    // but skip the implicit `withAnimation` so the transition is instant.
    let dropFill = group.tone.color.opacity(
      isFlashing ? 0.32 : (isHighlighted ? 0.26 : 0.16)
    )
    let baselineStrokeOpacity = isSelected || isHighlighted ? 0.88 : 0.42
    let dashedLineWidth: CGFloat
    if isFlashing || isHighlighted {
      dashedLineWidth = 2.4
    } else if isSelected {
      dashedLineWidth = 1.6
    } else {
      dashedLineWidth = 1
    }

    return ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: PolicyCanvasLayout.groupCornerRadius)
        .fill(dropFill)
        .overlay {
          RoundedRectangle(cornerRadius: PolicyCanvasLayout.groupCornerRadius)
            .stroke(
              group.tone.color.opacity(baselineStrokeOpacity),
              style: StrokeStyle(lineWidth: dashedLineWidth, dash: [6, 5])
            )
        }
        .overlay {
          // Acceptance-flash overlay: a solid accent ring on top of the
          // dashed border, snapped on instantly under reduced motion and
          // eased in/out otherwise. The ring fades out via the binding
          // flipping back to false after `groupAcceptanceFlashDuration`.
          if isFlashing {
            RoundedRectangle(cornerRadius: PolicyCanvasLayout.groupCornerRadius)
              .stroke(group.tone.color.opacity(0.95), lineWidth: 2.4)
              .transition(reduceMotion ? .identity : .opacity)
          }
        }
        .animation(
          reduceMotion ? nil : .easeOut(duration: 0.22),
          value: isFlashing
        )

      Text(group.title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(group.tone.color.opacity(0.95))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.34), in: Capsule())
        .padding(10)
    }
    .frame(width: group.frame.width, height: group.frame.height)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(group.title)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasGroup(group.id))
  }
}
