import HarnessMonitorKit
import Observation
import SwiftUI

struct PolicyCanvasTopBar: View {
  @Bindable var viewModel: PolicyCanvasViewModel
  let canPromote: Bool
  let save: @MainActor () -> Void
  let simulate: @MainActor () -> Void
  let promote: @MainActor () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Label("Configurable Policy Canvas", systemImage: "rectangle.3.group.bubble")
        .scaledFont(.headline.weight(.semibold))
        .foregroundStyle(.white)

      Picker("Canvas mode", selection: $viewModel.selectedTab) {
        ForEach(PolicyCanvasTab.allCases) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 290)
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasTabs)

      Spacer(minLength: 16)

      if viewModel.hasPendingDocumentUpdate {
        Button {
          viewModel.applyPendingUpdate()
        } label: {
          Label("Remote changes available - reload?", systemImage: "arrow.triangle.2.circlepath")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .orange)
        .controlSize(.small)
        .help("Apply the latest pipeline from the dashboard and discard local edits.")
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasReloadButton)
      }

      PolicyCanvasActionButton(
        title: "Save",
        systemImage: "square.and.arrow.down",
        accessibilityIdentifier: HarnessMonitorAccessibility.policyCanvasSaveButton,
        action: {
          viewModel.save()
          save()
        }
      )

      PolicyCanvasActionButton(
        title: "Simulate",
        systemImage: "play.circle",
        accessibilityIdentifier: HarnessMonitorAccessibility.policyCanvasSimulateButton,
        action: {
          viewModel.simulate()
          simulate()
        }
      )

      VStack(alignment: .trailing, spacing: 2) {
        PolicyCanvasActionButton(
          title: "Promote",
          systemImage: "arrow.up.right.circle",
          tint: Color.green,
          isDisabled: !canPromote,
          disabledReason: viewModel.promoteDisabledReason,
          accessibilityIdentifier: HarnessMonitorAccessibility.policyCanvasPromoteButton,
          action: {
            viewModel.promote()
            promote()
          }
        )

        if let reason = viewModel.promoteDisabledReason {
          // White at 78% opacity reads ~5.6:1 on the top bar backdrop
          // `#14171F` — clears WCAG AA for small text without competing with
          // the action button glyph color.
          Text(reason)
            .scaledFont(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.policyCanvasPromoteDisabledReason
            )
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.98))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.white.opacity(0.08))
        .frame(height: 1)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasTopBar)
  }
}

private struct PolicyCanvasActionButton: View {
  let title: String
  let systemImage: String
  var tint = Color.cyan
  var isDisabled = false
  var disabledReason: String?
  let accessibilityIdentifier: String
  let action: @MainActor () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .scaledFont(.callout.weight(.semibold))
        .lineLimit(1)
    }
    .harnessActionButtonStyle(variant: .bordered, tint: tint.opacity(0.85))
    .controlSize(.small)
    .disabled(isDisabled)
    .help(isDisabled ? disabledReason ?? title : title)
    .accessibilityIdentifier(accessibilityIdentifier)
  }
}

struct PolicyCanvasToolRail: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    VStack(spacing: 10) {
      ForEach(PolicyCanvasNodeKind.allCases) { kind in
        Button {
          viewModel.createNode(kind: kind, at: CGPoint(x: 180, y: 180))
        } label: {
          VStack(spacing: 5) {
            Image(systemName: kind.symbolName)
              .scaledFont(.system(size: 15, weight: .semibold))
            Text(kind.title)
              .scaledFont(.caption2.weight(.semibold))
              .lineLimit(1)
          }
          .foregroundStyle(kind.accentColor)
          .frame(width: 64, height: 52)
          .background(kind.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .stroke(kind.accentColor.opacity(0.38), lineWidth: 1)
          }
        }
        .harnessPlainButtonStyle()
        .draggable(viewModel.palettePayload(for: kind))
        .help("Add \(kind.title)")
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasPaletteItem(kind.rawValue))
      }

      Spacer(minLength: 0)
    }
    .padding(.vertical, 14)
    .padding(.horizontal, 8)
    .frame(width: 84)
    .background(Color(red: 0.07, green: 0.08, blue: 0.11))
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(.white.opacity(0.07))
        .frame(width: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasToolRail)
  }
}

struct PolicyCanvasZoomControls: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    HStack(spacing: 6) {
      Button {
        viewModel.zoomOut()
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      .keyboardShortcut("-", modifiers: [.command])
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomOutButton)

      Text("\(Int((viewModel.zoom * 100).rounded()))%")
        .scaledFont(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(.white.opacity(0.86))
        .frame(width: 46)
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomValue)

      Button {
        viewModel.zoomIn()
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      .keyboardShortcut("+", modifiers: [.command])
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomInButton)

      Button {
        viewModel.resetZoom()
      } label: {
        Image(systemName: "arrow.counterclockwise")
      }
      .keyboardShortcut("0", modifiers: [.command])
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomResetButton)
    }
    .harnessActionButtonStyle(variant: .borderless)
    .controlSize(.small)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.white.opacity(0.12), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomControls)
  }
}
