import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

/// Layer of group regions rendered behind the nodes. Pulled out of
/// `PolicyCanvasWorkspaceViews.swift` so the workspace file stays under the
/// 420-line cap; Wave 4K added the acceptance-flash + thicker drop affordance
/// state to `PolicyCanvasGroupRegion`, which pushed the workspace file over
/// the limit.
struct PolicyCanvasGroupLayer: View {
  let viewModel: PolicyCanvasViewModel
  let focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding
  let openEditor: @MainActor (PolicyCanvasEditSheet) -> Void
  @Environment(\.policyCanvasReducedMotion)
  private var canvasReducedMotion
  @Environment(\.accessibilityReduceMotion)
  private var systemReduceMotion

  private var reducedMotion: Bool {
    canvasReducedMotion ?? systemReduceMotion
  }

  var body: some View {
    ForEach(viewModel.groups) { group in
      PolicyCanvasGroupRegion(
        group: group,
        isSelected: viewModel.isSelected(.group(group.id)),
        isHighlighted: viewModel.highlightedGroupID == group.id,
        isFlashing: viewModel.groupAcceptanceFlashID == group.id
      )
      .position(x: group.frame.midX, y: group.frame.midY)
      .accessibilityFocused(focusedComponent, equals: .group(group.id))
      .gesture(
        DragGesture(minimumDistance: 3)
          .onChanged { value in
            viewModel.dragGroup(group.id, translation: value.translation)
          }
          .onEnded { value in
            withAnimation(PolicyCanvasMotion.spring(reducedMotion: reducedMotion)) {
              viewModel.endGroupDrag(group.id, translation: value.translation)
            }
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
      .onTapGesture(count: 2) {
        viewModel.select(.group(group.id))
        openEditor(.group(group.id))
      }
      .contextMenu {
        Button("Edit") {
          viewModel.select(.group(group.id))
          openEditor(.group(group.id))
        }
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
  @Environment(\.policyCanvasReducedMotion)
  private var canvasReducedMotion
  @Environment(\.accessibilityReduceMotion)
  private var systemReduceMotion
  @Environment(\.colorScheme)
  private var colorScheme

  private var reducedMotion: Bool {
    canvasReducedMotion ?? systemReduceMotion
  }

  var body: some View {
    let dashedLineWidth: CGFloat
    if isFlashing || isHighlighted {
      dashedLineWidth = 1.8
    } else if isSelected {
      dashedLineWidth = 1.3
    } else {
      dashedLineWidth = 1
    }

    return ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: PolicyCanvasLayout.groupCornerRadius)
        .fill(
          PolicyCanvasVisualStyle.groupFill(
            group.tone,
            colorScheme: colorScheme,
            isHighlighted: isHighlighted,
            isFlashing: isFlashing
          )
        )
        .overlay {
          RoundedRectangle(cornerRadius: PolicyCanvasLayout.groupCornerRadius)
            .stroke(
              PolicyCanvasVisualStyle.groupStroke(
                group.tone,
                colorScheme: colorScheme,
                isSelected: isSelected,
                isHighlighted: isHighlighted,
                isFlashing: isFlashing
              ),
              style: StrokeStyle(lineWidth: dashedLineWidth, dash: [6, 5])
            )
            .policyCanvasSelectionMark(value: isSelected, reducedMotion: reducedMotion)
        }
        .overlay {
          if isFlashing {
            RoundedRectangle(cornerRadius: PolicyCanvasLayout.groupCornerRadius)
              .stroke(
                PolicyCanvasVisualStyle.groupStroke(
                  group.tone,
                  colorScheme: colorScheme,
                  isSelected: isSelected,
                  isHighlighted: true,
                  isFlashing: true
                ),
                lineWidth: 1.8
              )
              .transition(reducedMotion ? .identity : .opacity)
          }
        }
        .animation(
          reducedMotion ? nil : .easeOut(duration: 0.22),
          value: isFlashing
        )

      Text(group.title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          PolicyCanvasVisualStyle.groupTitleBackground(group.tone, colorScheme: colorScheme),
          in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius)
        )
        .overlay {
          RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius)
            .stroke(group.tone.color.opacity(colorScheme == .dark ? 0.26 : 0.30), lineWidth: 1)
        }
        .padding(10)
    }
    .frame(width: group.frame.width, height: group.frame.height)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(group.title)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasGroup(group.id))
  }
}
